#!/bin/bash
#
# ShotKeeper one-command release.
#
#   1. In Xcode (target ▸ General) bump Version and/or Build.
#   2. Run:  ./release.sh
#   3. In GitHub Desktop: commit docs/ and Push origin.
#   4. In the installed app: Settings ▸ About ▸ Check for Updates.
#
# It archives a Release build, extracts the .app, zips it into docs/,
# signs it with your Sparkle private key, and rewrites docs/appcast.xml.

set -euo pipefail

# ---- config (specific to bamin2/ShotKeeper) ----
SCHEME="ShotKeeper"
URL_PREFIX="https://bamin2.github.io/ShotKeeper/"
# ------------------------------------------------

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$PROJECT_DIR/$SCHEME.xcodeproj"
DOCS="$PROJECT_DIR/docs"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
LOG="$BUILD_DIR/last-build.log"

mkdir -p "$BUILD_DIR" "$DOCS"

echo "▶︎ Archiving $SCHEME (Release)…"
rm -rf "$ARCHIVE"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -archivePath "$ARCHIVE" -allowProvisioningUpdates archive \
        > "$LOG" 2>&1; then
    echo "✗ Archive failed. Last lines of $LOG:"
    tail -25 "$LOG"
    exit 1
fi

APP="$ARCHIVE/Products/Applications/$SCHEME.app"
[ -d "$APP" ] || { echo "✗ No app found at $APP"; exit 1; }

VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)
BUILD_NUM=$(defaults read "$APP/Contents/Info" CFBundleVersion)
echo "▶︎ Built $SCHEME $VERSION (build $BUILD_NUM)"

ZIP="$DOCS/$SCHEME-$VERSION.zip"
echo "▶︎ Zipping → $(basename "$ZIP")"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Find Sparkle's generate_appcast (from the SwiftPM artifacts, or $SPARKLE_BIN).
GEN="${SPARKLE_BIN:-}/generate_appcast"
if [ ! -x "$GEN" ]; then
    GEN=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name generate_appcast -type f 2>/dev/null | head -1)
fi
[ -x "$GEN" ] || { echo "✗ generate_appcast not found. Set SPARKLE_BIN to your Sparkle bin folder."; exit 1; }

echo "▶︎ Signing + writing appcast…"
"$GEN" --download-url-prefix "$URL_PREFIX" "$DOCS"

echo ""
echo "✅ Packaged $SCHEME $VERSION (build $BUILD_NUM)."
echo "   Next: GitHub Desktop → commit docs/ → Push origin,"
echo "   then Check for Updates in the installed app."
