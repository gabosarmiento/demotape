#!/bin/bash
# Builds DemoTape and packages it into a distributable .dmg (drag-to-Applications).
#
# The app is AD-HOC signed (codesign -s -), not signed with an Apple Developer ID
# and NOT notarized. That means testers will hit Gatekeeper on first launch and
# must right-click > Open (or clear the quarantine flag). See the instructions
# printed at the end and in README.md ("Install from the .dmg (testers)").
#
# Why ad-hoc and not the local "DemoTape Dev" cert? That self-signed identity only
# exists in *your* Keychain and means nothing on someone else's Mac. Ad-hoc is the
# minimum signature required for the binary to launch at all (mandatory on Apple
# Silicon, tolerated on Intel).
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="DemoTape"
BUNDLE="${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo dev)"
DIST_DIR="dist"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
VOL_NAME="${APP_NAME} ${VERSION}"
STAGE_ROOT="$(mktemp -d)"
STAGE="${STAGE_ROOT}/${APP_NAME}"

# Ship a universal binary so the download runs natively on both Apple Silicon
# and Intel (no Rosetta). Cross-compiling both slices works from either host
# with recent Command Line Tools.
ARCHS=(--arch arm64 --arch x86_64)

cleanup() { rm -rf "${STAGE_ROOT}"; }
trap cleanup EXIT

echo "==> Building universal (${CONFIG}: arm64 + x86_64)..."
swift build -c "${CONFIG}" "${ARCHS[@]}"
BIN_PATH="$(swift build -c "${CONFIG}" "${ARCHS[@]}" --show-bin-path)/${APP_NAME}"

echo "==> Assembling ${BUNDLE} (v${VERSION})..."
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN_PATH}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${BUNDLE}/Contents/Info.plist"
echo "    architectures: $(lipo -archs "${BUNDLE}/Contents/MacOS/${APP_NAME}")"
[ -f "Resources/AppIcon.icns" ]   && cp "Resources/AppIcon.icns"   "${BUNDLE}/Contents/Resources/AppIcon.icns"
[ -f "Resources/MenuBarIcon.png" ] && cp "Resources/MenuBarIcon.png" "${BUNDLE}/Contents/Resources/MenuBarIcon.png"
if [ -d "Resources/background" ]; then
    mkdir -p "${BUNDLE}/Contents/Resources/background"
    cp Resources/background/*.png "${BUNDLE}/Contents/Resources/background/" 2>/dev/null || true
fi

echo "==> Ad-hoc code signing (for distribution)..."
codesign --force --deep --sign - "${BUNDLE}"
codesign --verify --deep --strict "${BUNDLE}" && echo "    signature OK (ad-hoc)"

echo "==> Staging disk image contents..."
mkdir -p "${STAGE}"
cp -R "${BUNDLE}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

echo "==> Creating ${DMG_PATH}..."
mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}"
hdiutil create \
    -volname "${VOL_NAME}" \
    -srcfolder "${STAGE}" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "${DMG_PATH}" >/dev/null

echo ""
echo "==> Done: ${DMG_PATH}"
echo ""
echo "Share this file with testers. Because it is NOT notarized, on first launch"
echo "macOS will block it. Tell testers to either:"
echo "  * Right-click DemoTape.app in /Applications > Open > Open, OR"
echo "  * Run: xattr -dr com.apple.quarantine /Applications/DemoTape.app"
echo ""
echo "Attach to a GitHub release with:"
echo "  gh release upload v${VERSION} \"${DMG_PATH}\""
