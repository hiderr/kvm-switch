#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="KVM Switch.app"
BIN="$APP/Contents/MacOS/kvm-switch"

echo "compiling kvm-switch..."
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -o "$BIN" main.swift \
  -framework CoreGraphics \
  -framework Foundation \
  -framework Network \
  -framework AppKit

# Ad-hoc sign the whole bundle so TCC (Accessibility / Input Monitoring)
# permissions persist across rebuilds instead of re-prompting every time.
codesign --force --deep --sign - "$APP"

echo "done -> $(pwd)/$APP"
echo "binary: $(pwd)/$BIN"
