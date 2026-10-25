#!/bin/bash
# Builds SimpleSKP.app in release mode, packages build/SimpleSKP-<version>.zip,
# computes its SHA-256 checksum, and prints the JSON manifest snippet for SimpleUpdater.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="$(./Scripts/bundle.sh release | tail -1)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
ZIP_PATH="build/SimpleSKP-${VERSION}.zip"

rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

cat <<EOF
=== Packaged Release ===
Archive: $ZIP_PATH
Version: $VERSION (build $BUILD)
SHA-256: $SHA256

JSON manifest snippet:
{
  "net.cieadrienm.simpleskp": {
    "version": "$VERSION",
    "build": $BUILD,
    "url": "https://github.com/cieadrienm/SimpleSKP/releases/download/v$VERSION/SimpleSKP-$VERSION.zip",
    "sha256": "$SHA256",
    "notes_fr": "Mise à jour SimpleSKP v$VERSION",
    "notes_en": "SimpleSKP v$VERSION update"
  }
}
EOF
