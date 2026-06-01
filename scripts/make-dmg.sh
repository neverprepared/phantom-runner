#!/usr/bin/env bash
# Build a distributable DMG for BrainboxRunner.
# Usage: ./scripts/make-dmg.sh [output-dir]
#
# Produces BrainboxRunner-<version>.dmg in the output dir (default: dist/).
# Ad-hoc signs the app so macOS doesn't refuse to open it on the first try.
# For a notarized release build use the runner-release CI workflow instead.

set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT_DIR="${1:-dist}"
mkdir -p "$OUTPUT_DIR"

SCHEME="BrainboxRunner"
PROJECT="BrainboxRunner.xcodeproj"
CONFIG="Release"

echo ">> Building ${SCHEME} (${CONFIG})..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData \
  build \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY="-" \
  2>&1 | grep -E "^(error:|warning:.*error|.*BUILD)"

APP_SRC="build/DerivedData/Build/Products/${CONFIG}/${SCHEME}.app"

if [ ! -d "$APP_SRC" ]; then
  echo "ERROR: Build output not found: ${APP_SRC}" >&2
  exit 1
fi

# Read version from the built app (Xcode expands $(MARKETING_VERSION) there)
VERSION=$(
  /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "${APP_SRC}/Contents/Info.plist" 2>/dev/null || echo "0.0.0"
)
DMG_NAME="BrainboxRunner-${VERSION}.dmg"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"

echo ">> Ad-hoc signing ${SCHEME} ${VERSION}..."
codesign --force --deep --sign - "$APP_SRC"

echo ">> Staging DMG contents..."
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_SRC" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo ">> Creating ${DMG_NAME}..."
hdiutil create \
  -volname "Brainbox Runner" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" \
  > /dev/null

echo "OK: ${DMG_PATH} ($(du -sh "$DMG_PATH" | cut -f1))"
echo ""
echo "Install on remote Mac:"
echo "  scp ${DMG_PATH} user@remote-mac:~/"
echo "  ssh user@remote-mac 'hdiutil attach ~/$(basename "$DMG_PATH") && cp -R /Volumes/\"Brainbox Runner\"/BrainboxRunner.app /Applications/ && hdiutil detach /Volumes/\"Brainbox Runner\" && xattr -dr com.apple.quarantine /Applications/BrainboxRunner.app'"
