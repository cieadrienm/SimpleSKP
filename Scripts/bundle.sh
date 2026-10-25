#!/bin/bash
# Builds build/SimpleSKP.app (host architecture); a release build is also installed into /Applications (INSTALL=0 to skip).
# Usage: Scripts/bundle.sh [debug|release]   (default: release)
# SIGN_IDENTITY="Developer ID Application: …" Scripts/bundle.sh   signs with that identity ("-" for ad hoc)
# NOTARIZE=1 Scripts/bundle.sh   also has Apple notarize the app and staples the ticket (Developer ID, notarytool profile "notary")
set -euo pipefail
cd "$(dirname "$0")/.."
# The version shown by the Finder, About and the status bar: bump it here, and only here (CHANGELOG.md says
# what changed; a release is tagged vX.Y.Z). The build number counts commits.
VERSION="1.0.0"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
CONFIG="${1:-release}"

if [ ! -f Resources/AppIcon.icns ]; then
    swift Scripts/make-icon.swift
fi

swift build -c "$CONFIG" --product SimpleSKP
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="${APP:-build/SimpleSKP.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
cp "$BIN/SimpleSKP" "$APP/Contents/MacOS/SimpleSKP"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stamped in the bundle's copy only: Resources/Info.plist keeps the placeholders
sed -i '' -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" "$APP/Contents/Info.plist"
if grep -q '@VERSION@\|@BUILD@' "$APP/Contents/Info.plist"; then
    echo "error: the version was not stamped into the app's Info.plist" >&2
    exit 1
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Localisations: AppKit shows its own strings (Sans titre / Untitled, Ouvrir / Open…) in French or English.
for LPROJ in Resources/*.lproj; do
    [ -d "$LPROJ" ] && cp -R "$LPROJ" "$APP/Contents/Resources/"
done

# Signing. A real identity keeps the app's identity stable across rebuilds.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGN_IDENTITY="$(echo "$IDENTITIES" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="$(echo "$IDENTITIES" | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
fi
# Developer ID: hardened runtime + secure timestamp (notarization). The app dlopens a framework signed by
# Trimble, so library validation must be off (D10); without the hardened runtime nothing needs it.
case "$SIGN_IDENTITY" in
    "Developer ID Application:"*) SIGN_FLAGS=(--timestamp --options runtime --entitlements Resources/SimpleSKP.entitlements) ;;
    *) SIGN_FLAGS=(--timestamp=none) ;;
esac
if ! codesign --force "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$APP" 2>build/codesign.log; then
    echo "warning: signing with '$SIGN_IDENTITY' failed ($(tail -1 build/codesign.log)); signing ad hoc instead" >&2
    SIGN_IDENTITY="-"
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "signed: $SIGN_IDENTITY" >&2

if [ "${NOTARIZE:-0}" = "1" ]; then
    case "$SIGN_IDENTITY" in
        "Developer ID Application:"*) ;;
        *) echo "error: NOTARIZE=1 needs a Developer ID Application certificate" >&2; exit 1 ;;
    esac
    ditto -c -k --keepParent "$APP" "$APP.notarize.zip"
    xcrun notarytool submit "$APP.notarize.zip" --keychain-profile "${NOTARY_PROFILE:-notary}" --wait
    rm -f "$APP.notarize.zip"
    xcrun stapler staple "$APP"
    echo "notarized and stapled" >&2
fi

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
if [ "${INSTALL:-$([ "$CONFIG" = release ] && echo 1 || echo 0)}" = 1 ]; then
    TARGET="$INSTALL_DIR/SimpleSKP.app"
    if pgrep -f "$TARGET/Contents/MacOS/SimpleSKP" >/dev/null; then
        echo "note: SimpleSKP is running from $TARGET — quit and reopen it to get this build" >&2
    fi
    rm -rf "$TARGET.new"
    ditto "$APP" "$TARGET.new"
    rm -rf "$TARGET"
    mv "$TARGET.new" "$TARGET"
    echo "installed: $TARGET" >&2
fi
echo "$APP"
