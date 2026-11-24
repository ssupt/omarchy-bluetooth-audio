#!/usr/bin/env python3
"""Detect stale source, binary, and metadata in a staged plugin."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "packaging"))
import release  # noqa: E402


with tempfile.TemporaryDirectory(prefix="bluetooth-release-test-") as temporary:
    staged = Path(temporary)
    for relative in release.source_files(ROOT) + [release.BINARY, release.METADATA]:
        destination = staged / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, destination)
    release.verify(staged)

    # Adding a top-level QML file without rebuilding must fail release verification.
    added_qml = staged / "AddedReleaseProbe.qml"
    added_qml.write_text("import QtQuick\nItem {}\n")
    try:
        release.verify(staged)
        raise AssertionError("Added top-level QML file was accepted without rebuild")
    except ValueError:
        pass
    added_qml.unlink()

    script = staged / "scripts/bluetooth-device-action"
    original = script.read_bytes()
    script.write_bytes(original + b"\n# changed\n")
    try:
        release.verify(staged)
        raise AssertionError("Changed helper was accepted")
    except ValueError:
        pass
    script.write_bytes(original)

    binary = staged / release.BINARY
    with binary.open("ab") as stream:
        stream.write(b"changed")
    try:
        release.verify(staged)
        raise AssertionError("Changed binary was accepted")
    except ValueError:
        pass

    # Consecutive no-change Cargo checks using the default backend/target dir
    # must stay incremental instead of rebuilding on build-output writes.
    check_cmd = [
        "cargo", "check", "--locked", "--offline",
        "--manifest-path", str(staged / "backend/Cargo.toml"),
    ]
    first_check = subprocess.run(check_cmd, check=True, capture_output=True, text=True)
    assert "omarchy-bluetooth-service" in first_check.stderr, first_check.stderr
    second_check = subprocess.run(check_cmd, check=True, capture_output=True, text=True)
    assert "omarchy-bluetooth-service" not in second_check.stderr, second_check.stderr

    # Adding a top-level QML file without listing it in packaging/sources.txt
    # must be rejected; listing it must trigger an incremental rebuild that
    # updates BLUETOOTH_BUILD_ID.
    build_cmd = [
        "cargo", "build", "--locked", "--offline",
        "--manifest-path", str(staged / "backend/Cargo.toml"),
    ]
    subprocess.run(build_cmd, check=True, capture_output=True, text=True)
    built_binary = staged / "backend/target/debug/omarchy-bluetooth-service"
    before = release.checked_info(staged, built_binary)
    added_qml.write_text("import QtQuick\nItem {}\n")
    try:
        release.checked_info(staged, built_binary)
        raise AssertionError("Unlisted top-level QML file was accepted")
    except ValueError:
        pass
    manifest_file = staged / release.SOURCES_MANIFEST
    listed = sorted(manifest_file.read_text().splitlines() + [added_qml.name])
    manifest_file.write_text("\n".join(listed) + "\n")
    subprocess.run(build_cmd, check=True, capture_output=True, text=True)
    after = release.checked_info(staged, built_binary)
    assert after["sourceId"] != before["sourceId"], (before, after)

    # Prepared release metadata must stay world-readable (0644), not 0600.
    release.prepare(staged, built_binary)
    metadata_mode = (staged / release.METADATA).stat().st_mode & 0o777
    assert metadata_mode == 0o644, oct(metadata_mode)

print("PASS: release verification rejects changed sources and binary")
