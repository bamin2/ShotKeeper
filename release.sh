#!/bin/bash
#
# ShotKeeper one-command notarized release.
#
#   1. In Xcode (target ▸ General) bump Version and/or Build.
#   2. Run:  ./release.sh
#   3. In GitHub Desktop: commit docs/ and Push origin.
#   4. In the installed app: Settings ▸ About ▸ Check for Updates.
#
# Pipeline: archive → export (Developer ID) → notarize → staple →
#           zip into docs/ → Sparkle-sign → rewrite docs/appcast.xml.

set -euo pipefail

# ---- config (specific to bamin2 / DGC / ShotKeeper) ----
SCHEME="ShotKeeper"
URL_PREFIX="https://bamin2.github.io/ShotKeeper/"
NOTARY_PROFILE="ShotKeeper-notary"
# --------------------------------------------------------

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$PROJECT_DIR/$SCHEME.xcodeproj"
DOCS="$PROJECT_DIR/docs"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTS="$PROJECT_DIR/exportOptions.plist"
LOG="$BUILD_DIR/last-build.log"

mkdir -p "$BUILD_DIR" "$DOCS"

# 1. Archive ------------------------------------------------------------------
echo "▶︎ Archiving $SCHEME (Release)…"
rm -rf "$ARCHIVE"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -archivePath "$ARCHIVE" -allowProvisioningUpdates archive \
        > "$LOG" 2>&1; then
    echo "✗ Archive failed. Last lines of $LOG:"; tail -25 "$LOG"; exit 1
fi

# 2. Export with Developer ID signing -----------------------------------------
echo "▶︎ Exporting (Developer ID)…"
rm -rf "$EXPORT_DIR"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$EXPORT_OPTS" -exportPath "$EXPORT_DIR" \
        -allowProvisioningUpdates >> "$LOG" 2>&1; then
    echo "✗ Export failed. Last lines of $LOG:"; tail -25 "$LOG"; exit 1
fi

APP="$EXPORT_DIR/$SCHEME.app"
[ -d "$APP" ] || { echo "✗ No exported app at $APP"; exit 1; }

VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)
BUILD_NUM=$(defaults read "$APP/Contents/Info" CFBundleVersion)
echo "▶︎ Exported $SCHEME $VERSION (build $BUILD_NUM)"

# 3. Notarize (submit a zip, wait for the result) -----------------------------
NOTARIZE_ZIP="$BUILD_DIR/$SCHEME-notarize.zip"
echo "▶︎ Zipping for notarization…"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"

echo "▶︎ Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

# 4. Staple the ticket onto the .app ------------------------------------------
echo "▶︎ Stapling…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 5. Final distributable zip (stapled app) ------------------------------------
ZIP="$DOCS/$SCHEME-$VERSION.zip"
echo "▶︎ Zipping notarized app → $(basename "$ZIP")"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 6. Sparkle: sign + write the appcast ----------------------------------------
GEN="${SPARKLE_BIN:-}/generate_appcast"
if [ ! -x "$GEN" ]; then
    GEN=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name generate_appcast -type f 2>/dev/null | head -1)
fi
[ -x "$GEN" ] || { echo "✗ generate_appcast not found. Set SPARKLE_BIN to your Sparkle bin folder."; exit 1; }

echo "▶︎ Sparkle-signing + writing appcast…"
"$GEN" --download-url-prefix "$URL_PREFIX" "$DOCS"

# 7. Build a signed + notarized DMG installer (for first-time downloads) -------
DMG="$BUILD_DIR/$SCHEME-$VERSION.dmg"
if command -v create-dmg >/dev/null 2>&1; then
    echo "▶︎ Building DMG installer…"
    STAGE="$BUILD_DIR/dmg-stage"
    rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    create-dmg \
        --volname "$SCHEME" \
        --window-size 540 380 \
        --icon "$SCHEME.app" 140 190 \
        --app-drop-link 400 190 \
        "$DMG" "$STAGE" || true

    if [ -f "$DMG" ]; then
        SIGN_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -n "$SIGN_ID" ]; then
            echo "▶︎ Signing + notarizing DMG (another notary wait)…"
            codesign --force --sign "$SIGN_ID" "$DMG"
            xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
            xcrun stapler staple "$DMG"
            echo "   ✅ DMG ready → $DMG"
        else
            echo "   ⚠︎ No Developer ID identity found — DMG built but unsigned: $DMG"
        fi
    else
        echo "   ⚠︎ create-dmg produced no file; skipped."
    fi
else
    echo "   ⚠︎ create-dmg not installed — skipped DMG (run: brew install create-dmg)."
fi

echo ""
echo "✅ Notarized & packaged $SCHEME $VERSION (build $BUILD_NUM)."
echo "   • Update zip + appcast: $DOCS  → commit & Push in GitHub Desktop"
[ -f "$DMG" ] && echo "   • Installer DMG: $DMG  → upload to a GitHub Release"
