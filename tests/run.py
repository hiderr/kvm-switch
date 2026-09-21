#!/usr/bin/env python3
"""Compile the real app and same-file tests, without starting its UI/event tap."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "main.swift").read_text()
marker = "// MARK: - Entry point"
assert source.count(marker) == 1, "App entry point marker changed; review test runner"
with tempfile.TemporaryDirectory(prefix="kvm-switch-tests-") as directory:
    temporary = Path(directory)
    swift = temporary / "main.swift"
    swift.write_text(source.split(marker)[0] + "\n" + (root / "tests/NodeTests.swift").read_text())
    binary = temporary / "node-tests"
    subprocess.run(["swiftc", "-o", str(binary), str(swift), "-framework", "CoreGraphics",
                    "-framework", "Foundation", "-framework", "Network", "-framework", "AppKit"], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
