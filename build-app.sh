#!/bin/bash
# Packages DemoTape into a runnable .app bundle and ad-hoc code-signs it.
# No Xcode required -- uses the Swift toolchain from Command Line Tools.
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="DemoTape"
BUNDLE="${APP_NAME}.app"

echo "==> Building (${CONFIG})..."
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"

echo "==> Assembling ${BUNDLE}..."
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${BUNDLE}/Contents/Info.plist"

# App icon (Finder, alert dialogs) + menu-bar status icon.
[ -f "Resources/AppIcon.icns" ] && cp "Resources/AppIcon.icns" "${BUNDLE}/Contents/Resources/AppIcon.icns"
[ -f "Resources/MenuBarIcon.png" ] && cp "Resources/MenuBarIcon.png" "${BUNDLE}/Contents/Resources/MenuBarIcon.png"

# Bundle background images for framed (region) recordings.
if [ -d "Resources/background" ]; then
    mkdir -p "${BUNDLE}/Contents/Resources/background"
    cp Resources/background/*.png "${BUNDLE}/Contents/Resources/background/" 2>/dev/null || true
fi

echo "==> Code signing..."
# Sign with the SAME identity the shipped DMG uses, so macOS keeps every permission grant across
# rebuilds AND across the notarized DMG (TCC binds grants to the signing identity's designated
# requirement — mixing identities is what forces re-granting). Preference:
#   1. Developer ID Application  → identical designated requirement as the release DMG (grants persist forever)
#   2. "DemoTape Dev" self-signed → stable across local rebuilds, but differs from the DMG
#   3. ad-hoc                     → last resort (permission resets each rebuild)
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
ENTITLEMENTS="Resources/DemoTape.entitlements"
if [ -n "${SIGN_ID}" ]; then
    # Hardened runtime REQUIRES the matching entitlements (mic/camera/apple-events) or macOS kills
    # the app when it touches those — sign exactly like the release DMG does.
    codesign --force --deep --options runtime --entitlements "${ENTITLEMENTS}" --sign "${SIGN_ID}" "${BUNDLE}"
    echo "    signed with: ${SIGN_ID}"
elif security find-certificate -c "DemoTape Dev" >/dev/null 2>&1; then
    SIGN_ID="DemoTape Dev"
    codesign --force --deep --sign "DemoTape Dev" "${BUNDLE}"
    echo "    signed with: DemoTape Dev (self-signed; differs from the release DMG)"
else
    echo "    no signing identity found; run ./create-identity.sh once."
    codesign --force --deep --sign - "${BUNDLE}"
    echo "    signed ad-hoc (permission will reset on each rebuild)"
fi

# Install to /Applications. Screen Recording permission is unreliable for apps run
# from TCC-protected folders like ~/Desktop, ~/Documents, ~/Downloads.
INSTALL_DIR="/Applications"
echo "==> Installing to ${INSTALL_DIR}..."
rm -rf "${INSTALL_DIR}/${BUNDLE}"
cp -R "${BUNDLE}" "${INSTALL_DIR}/${BUNDLE}"
# Re-sign in place so the designated requirement stays identical across rebuilds.
if [ -n "${SIGN_ID}" ] && [ "${SIGN_ID}" != "-" ]; then
    if [ "${SIGN_ID}" = "DemoTape Dev" ]; then
        codesign --force --deep --sign "DemoTape Dev" "${INSTALL_DIR}/${BUNDLE}"
    else
        codesign --force --deep --options runtime --entitlements "${ENTITLEMENTS}" --sign "${SIGN_ID}" "${INSTALL_DIR}/${BUNDLE}"
    fi
fi

# Remove the local staging bundle. Leaving a second DemoTape.app in the project folder
# registers a duplicate with the same bundle id in LaunchServices, which makes macOS bind
# Screen Recording permission to the wrong copy — the app then reports "not granted" even
# though the box is ticked. Keep exactly one bundle: the installed /Applications one.
rm -rf "${BUNDLE}"

# Make sure LaunchServices knows about the installed copy (and only that one).
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "${LSREGISTER}" ] && "${LSREGISTER}" -f "${INSTALL_DIR}/${BUNDLE}" >/dev/null 2>&1 || true

echo "==> Done: ${INSTALL_DIR}/${BUNDLE}"
echo "Launch with:  open \"${INSTALL_DIR}/${BUNDLE}\""
echo "Run DemoTape ONLY from ${INSTALL_DIR} — running a copy from another folder registers a"
echo "duplicate bundle id and breaks Screen Recording permission."
