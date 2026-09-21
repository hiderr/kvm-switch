#!/usr/bin/env python3
"""Build actual Node + a full-keyboard LAN probe; never posts OS input."""
from pathlib import Path
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'main.swift').read_text()
marker = '// MARK: - Entry point'
assert source.count(marker) == 1
output = Path(sys.argv[1]).resolve()
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='kvm-lan-keyboard-') as temp:
    swift = Path(temp) / 'main.swift'
    swift.write_text(source.split(marker)[0] + '\n' + (root / 'tests/LANKeyboard.swift').read_text())
    subprocess.run(['swiftc', '-O', '-o', str(output), str(swift)], check=True)
print(output)
