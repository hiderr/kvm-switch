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

# Sign with a stable self-signed identity so the designated requirement stays
# pinned to the cert (not a per-build ad-hoc cdhash) and TCC grants
# (Accessibility / Input Monitoring) survive rebuilds. Falls back to ad-hoc if
# the identity is missing (run ./setup-signing.sh once to create it).
IDENTITY="KVM Switch Signing"
if security find-certificate -c "$IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "WARNING: '$IDENTITY' not found — falling back to ad-hoc (TCC will reset on rebuild)."
  echo "         run ./setup-signing.sh once to make permissions persist."
  codesign --force --deep --sign - "$APP"
fi

echo "done -> $(pwd)/$APP"
echo "binary: $(pwd)/$BIN"
