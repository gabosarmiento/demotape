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
# Prefer the stable self-signed "DemoTape Dev" identity so macOS keeps Screen
# Recording permission across rebuilds. Fall back to ad-hoc if it's missing.
if security find-certificate -c "DemoTape Dev" >/dev/null 2>&1; then
    codesign --force --deep --sign "DemoTape Dev" "${BUNDLE}"
    echo "    signed with: DemoTape Dev (stable identity)"
else
    echo "    'DemoTape Dev' identity not found; run ./create-identity.sh once."
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
if security find-certificate -c "DemoTape Dev" >/dev/null 2>&1; then
    codesign --force --deep --sign "DemoTape Dev" "${INSTALL_DIR}/${BUNDLE}"
fi

echo "==> Done: ${INSTALL_DIR}/${BUNDLE}"
echo "Launch with:  open \"${INSTALL_DIR}/${BUNDLE}\""
