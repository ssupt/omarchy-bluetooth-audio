#!/usr/bin/env python3
"""Detect stale source, binary, and metadata in a staged plugin."""

from pathlib import Path
import shutil
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

print("PASS: release verification rejects changed sources and binary")
