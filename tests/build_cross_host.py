#!/usr/bin/env python3
"""Build a transport-only probe using actual Node code, with no real OS input."""
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
with tempfile.TemporaryDirectory(prefix='kvm-cross-host-') as temp:
    swift = Path(temp) / 'main.swift'
    swift.write_text(source.split(marker)[0] + '\n' + (root / 'tests/CrossHost.swift').read_text())
    subprocess.run(['swiftc', '-o', str(output), str(swift), '-framework', 'CoreGraphics',
                    '-framework', 'Foundation', '-framework', 'Network', '-framework', 'AppKit'], check=True)
print(output)
