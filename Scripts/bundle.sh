#!/bin/bash
# Builds build/SimpleSKP.app (host architecture); a release build is also installed into /Applications (INSTALL=0 to skip).
# The SketchUp SDK framework ships inside the app (D1): $SKETCHUP_SDK, else Vendor/SketchUpAPI.framework, else Unity's copy.
# Usage: Scripts/bundle.sh [debug|release]   (default: release)
# SIGN_IDENTITY="Developer ID Application: …" Scripts/bundle.sh   signs with that identity ("-" for ad hoc)
# NOTARIZE=1 Scripts/bundle.sh   also has Apple notarize the app and staples the ticket (Developer ID, notarytool profile "notary")
set -euo pipefail
cd "$(dirname "$0")/.."
# The version shown by the Finder, About and the status bar: bump it here, and only here (CHANGELOG.md says
# what changed; a release is tagged vX.Y.Z). The build number counts commits.
VERSION="1.1.0"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
CONFIG="${1:-release}"

APP="${APP:-build/SimpleSKP.app}"
# It is deleted below: only ever a bundle under build/.
if [[ "$APP" != build/*.app || "$APP" == *..* ]]; then
    echo "error: APP must be a .app under build/ (got $APP)" >&2
    exit 1
fi

if [ ! -f Resources/AppIcon.icns ]; then
    swift Scripts/make-icon.swift
fi

swift build -c "$CONFIG" --product SimpleSKP
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
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
plutil -lint "$APP/Contents/Info.plist" >&2
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Localisations: AppKit shows its own strings (Sans titre / Untitled, Ouvrir / Open…) in French or English.
for LPROJ in Resources/*.lproj; do
    [ -d "$LPROJ" ] && cp -R "$LPROJ" "$APP/Contents/Resources/"
done

# The SketchUp SDK framework, so that the app reads files with no SketchUp installed (D1). Not committed (Vendor/ is ignored).
SDK="${SKETCHUP_SDK:-}"
[ -n "$SDK" ] || [ ! -d Vendor/SketchUpAPI.framework ] || SDK=Vendor/SketchUpAPI.framework
[ -n "$SDK" ] || SDK="$(ls -d /Applications/Unity/Hub/Editor/*/Unity.app/Contents/Frameworks/SketchUpAPI.framework 2>/dev/null | sort -V | tail -1 || true)"
if [ -z "$SDK" ] || [ ! -f "$SDK/Versions/A/SketchUpAPI" ]; then
    echo "error: SketchUpAPI.framework not found (set SKETCHUP_SDK or put the SDK in Vendor/): the app does not work without it" >&2
    exit 1
fi
FW="$APP/Contents/Frameworks/SketchUpAPI.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SDK" "$FW"
rm -rf "$FW/Headers" "$FW/Versions/A/Headers"
ARCH="$(uname -m)"
# The SketchUp.app copy lacks these (its libCommon*.dylib live beside it and need the app's rpath): use the SDK or Unity's.
if ! ls "$FW"/Versions/A/Libraries/*.dylib >/dev/null 2>&1; then
    echo "error: $SDK has no Versions/A/Libraries/*.dylib: not a self-contained SDK (take the SketchUp SDK or Unity's copy)" >&2
    exit 1
fi
for MACHO in "$FW/Versions/A/SketchUpAPI" "$FW"/Versions/A/Libraries/*.dylib; do
    if [[ " $(lipo -archs "$MACHO") " != *" $ARCH "* ]]; then
        echo "error: $MACHO is built for $(lipo -archs "$MACHO"), not for this Mac ($ARCH)" >&2
        exit 1
    fi
    if [ "$(lipo -archs "$MACHO")" != "$ARCH" ]; then
        lipo -thin "$ARCH" "$MACHO" -output "$MACHO.thin"
        mv "$MACHO.thin" "$MACHO"
    fi
done
echo "SketchUp SDK: $SDK" >&2

# Signing. A real identity keeps the app's identity stable across rebuilds.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGN_IDENTITY="$(echo "$IDENTITIES" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="$(echo "$IDENTITIES" | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
    [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
fi
# Developer ID: hardened runtime + secure timestamp (notarization). The embedded framework is re-signed with the
# app's identity, so library validation passes; the entitlement that turns it off (D10) is kept anyway, harmless.
case "$SIGN_IDENTITY" in
    "Developer ID Application:"*) SIGN_FLAGS=(--timestamp --options runtime --entitlements Resources/SimpleSKP.entitlements) ;;
    *) SIGN_FLAGS=(--timestamp=none) ;;
esac
# Inside out: the framework's dylibs, the framework, then the app.
sign_all() {
    for LIB in "$FW"/Versions/A/Libraries/*.dylib "$FW" "$APP"; do
        codesign --force "$@" "$LIB" || return 1
    done
}
if ! sign_all "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" 2>build/codesign.log; then
    echo "warning: signing with '$SIGN_IDENTITY' failed ($(tail -1 build/codesign.log)); signing ad hoc instead" >&2
    SIGN_IDENTITY="-"
    sign_all --sign -
fi
codesign --verify --deep --strict "$APP"
echo "signed: $SIGN_IDENTITY" >&2
echo "app size: $(du -sh "$APP" | awk '{print $1}')" >&2

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
