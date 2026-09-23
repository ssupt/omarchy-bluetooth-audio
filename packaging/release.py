#!/usr/bin/env python3
"""Prepare or verify the bundled Bluetooth service against plugin sources."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


BINARY = Path("bin/omarchy-bluetooth-service")
METADATA = Path("backend-release.json")
TARGET = "x86_64-unknown-linux-gnu"


def source_files(root: Path) -> list[Path]:
    files = [
        Path("manifest.json"),
        Path("backend/Cargo.toml"),
        Path("backend/Cargo.lock"),
        Path("backend/build.rs"),
        Path("packaging/release.py"),
    ]
    files += [path.relative_to(root) for path in root.iterdir()
              if path.is_file() and path.suffix in (".qml", ".js")]
    for directory in ("scripts", "backend/src"):
        files += [path.relative_to(root) for path in (root / directory).rglob("*")
                  if path.is_file()]
    return sorted(files)


def source_id(root: Path) -> str:
    digest = hashlib.sha256()
    for relative in source_files(root):
        content = (root / relative).read_bytes()
        digest.update(relative.as_posix().encode())
        digest.update(b"\0")
        digest.update(str(len(content)).encode())
        digest.update(b"\0")
        digest.update(content)
    return digest.hexdigest()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def checked_info(root: Path, binary: Path) -> dict:
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f"Missing executable: {binary}")
    result = subprocess.run([str(binary.resolve()), "--build-info"],
                            capture_output=True, text=True, timeout=5, check=True)
    info = json.loads(result.stdout)
    if info != {"sourceId": source_id(root), "target": TARGET, "protocolVersion": 1}:
        raise ValueError(f"Binary build info does not match sources or target: {info}")
    return info


def expected_metadata(root: Path, binary: Path) -> dict:
    info = checked_info(root, binary)
    return {**info, "version": json.loads((root / "manifest.json").read_text())["version"],
            "sha256": sha256(binary)}


def verify(root: Path) -> None:
    expected = expected_metadata(root, root / BINARY)
    actual = json.loads((root / METADATA).read_text())
    if actual != expected:
        raise ValueError("Bundled binary metadata does not match the release")


def prepare(root: Path, binary: Path) -> None:
    checked_info(root, binary)
    target = root / BINARY
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as staged:
        staged_path = Path(staged.name)
    try:
        shutil.copy2(binary, staged_path)
        staged_path.chmod(0o755)
        os.replace(staged_path, target)
    finally:
        staged_path.unlink(missing_ok=True)
    metadata = expected_metadata(root, target)
    with tempfile.NamedTemporaryFile(mode="w", dir=root, delete=False) as staged:
        staged_path = Path(staged.name)
        json.dump(metadata, staged, sort_keys=True, indent=2)
        staged.write("\n")
    try:
        os.replace(staged_path, root / METADATA)
    finally:
        staged_path.unlink(missing_ok=True)
    verify(root)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", type=Path, metavar="PLUGIN_ROOT")
    mode.add_argument("--prepare", type=Path, metavar="PLUGIN_ROOT")
    mode.add_argument("--check-binary", type=Path, metavar="BINARY")
    parser.add_argument("--binary", type=Path, help="newly built binary for --prepare")
    args = parser.parse_args()
    root = (args.check or args.prepare or Path(__file__).resolve().parent.parent).resolve()
    try:
        if args.check:
            verify(root)
            print("PASS: bundled service matches committed sources")
        elif args.prepare:
            if args.binary is None:
                parser.error("--prepare requires --binary")
            prepare(root, args.binary.resolve())
            print("PASS: bundled service prepared and verified")
        else:
            checked_info(root, args.check_binary)
            print("PASS: built service matches committed sources")
    except (ValueError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
