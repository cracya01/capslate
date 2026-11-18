#!/bin/bash
# Build Translator.app in a system temp dir, install it to /Applications, relaunch.
# The temp build dir is removed afterwards, so only /Applications/Translator.app remains.
set -euo pipefail
cd "$(dirname "$0")"

WORK=$(mktemp -d -t translator-build)
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Translator.app"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos26.0 \
  Core.swift Engines.swift TranslateUI.swift SettingsUI.swift Translator.swift \
  -o "$APP/Contents/MacOS/Translator"

cp Info.plist "$APP/Contents/"
# Prefer a stable self-signed identity in the login keychain, so macOS permissions survive rebuilds.
# Without it, fall back to ad-hoc signing (permissions may need re-granting after each rebuild).
IDENTITY="Local Self-Signed Code Signing"
# No -v: a self-signed cert isn't "valid" (trusted), but codesign can still use it.
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "Signing identity \"$IDENTITY\" not found, using ad-hoc signing."
  codesign --force --sign - "$APP"
fi

pkill -x Translator || true
sleep 1
rm -rf /Applications/Translator.app
ditto "$APP" /Applications/Translator.app
open /Applications/Translator.app
echo "Installed /Applications/Translator.app"
