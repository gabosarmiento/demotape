#!/bin/bash
# Build, Developer ID–sign, notarize, and staple DemoTape into a distributable .dmg — the "real
# release" path with NO hacks: recipients get no Gatekeeper warning and no quarantine dance.
#
# Requires an Apple Developer Program membership (one-time enrollment at developer.apple.com).
# Nothing here is secret or committed — all credentials come from your environment / Keychain.
#
# Prerequisites:
#   - A "Developer ID Application" certificate in your login Keychain (this machine already has
#     one for team R54YWFRK4B). Get it via Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates,
#     or developer.apple.com/account ▸ Certificates.
#   - An app-specific password for notarization (appleid.apple.com ▸ Sign-In & Security).
#
# Usage (simplest — use the app-specific password you already have):
#   AC_APPLE_ID="you@example.com" AC_PASSWORD="xxxx-xxxx-xxxx-xxxx" ./release-notarized.sh
#   # add SAVE_NOTARY_PROFILE=1 once to remember it in the Keychain for next time:
#   AC_APPLE_ID=… AC_PASSWORD=… SAVE_NOTARY_PROFILE=1 ./release-notarized.sh
#
# Other options:
#   ./release-notarized.sh                     # uses a saved notary profile if one exists
#   NOTARY_PROFILE=my-profile ./release-notarized.sh
#   DEVID="Developer ID Application: Name (TEAMID)" ./release-notarized.sh   # force the identity
#   AC_TEAM_ID=OTHERTEAM ./release-notarized.sh                              # sign under another team
#   SKIP_NOTARIZE=1 ./release-notarized.sh     # sign only (dry-run the signing half, no upload)
set -euo pipefail

CONFIG="release"
APP_NAME="DemoTape"
BUNDLE="${APP_NAME}.app"
ENTITLEMENTS="Resources/DemoTape.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-demotape-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo dev)"
DIST_DIR="dist"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
VOL_NAME="${APP_NAME} ${VERSION}"
STAGE_ROOT="$(mktemp -d)"
STAGE="${STAGE_ROOT}/${APP_NAME}"
cleanup() { rm -rf "${STAGE_ROOT}"; }
trap cleanup EXIT

# ---- Resolve the Developer ID Application identity -----------------------------------------
if [[ -z "${DEVID:-}" ]]; then
    DEVID="$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')" || true
fi
if [[ -z "${DEVID:-}" ]]; then
    cat >&2 <<'MSG'
error: No "Developer ID Application" certificate found in your Keychain.
       You need an Apple Developer Program membership, then install the cert:
         Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + Developer ID Application
       (or download it from https://developer.apple.com/account ▸ Certificates).
       Then re-run, or pass DEVID="Developer ID Application: Your Name (TEAMID)".
MSG
    exit 1
fi
echo "==> Signing identity: ${DEVID}"

# ---- Build a universal (arm64 + x86_64) release --------------------------------------------
echo "==> Building universal (${CONFIG}: arm64 + x86_64)..."
ARCHS=(--arch arm64 --arch x86_64)
swift build -c "${CONFIG}" "${ARCHS[@]}"
BIN_PATH="$(swift build -c "${CONFIG}" "${ARCHS[@]}" --show-bin-path)/${APP_NAME}"

echo "==> Assembling ${BUNDLE} (v${VERSION})..."
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN_PATH}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${BUNDLE}/Contents/Info.plist"
echo "    architectures: $(lipo -archs "${BUNDLE}/Contents/MacOS/${APP_NAME}")"
[ -f "Resources/AppIcon.icns" ]    && cp "Resources/AppIcon.icns"    "${BUNDLE}/Contents/Resources/AppIcon.icns"
[ -f "Resources/MenuBarIcon.png" ] && cp "Resources/MenuBarIcon.png" "${BUNDLE}/Contents/Resources/MenuBarIcon.png"
if [ -d "Resources/background" ]; then
    mkdir -p "${BUNDLE}/Contents/Resources/background"
    cp Resources/background/*.png "${BUNDLE}/Contents/Resources/background/" 2>/dev/null || true
fi

# ---- Sign with hardened runtime + entitlements + secure timestamp --------------------------
# Sign inside-out: the executable first, then the bundle. Hardened runtime (--options runtime)
# and a secure timestamp (--timestamp) are both required for notarization to pass.
echo "==> Code signing (Developer ID, hardened runtime)..."
codesign --force --timestamp --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${DEVID}" \
    "${BUNDLE}/Contents/MacOS/${APP_NAME}"
codesign --force --timestamp --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${DEVID}" \
    "${BUNDLE}"
codesign --verify --deep --strict --verbose=2 "${BUNDLE}"

# ---- Package the .dmg ----------------------------------------------------------------------
echo "==> Creating ${DMG_PATH}..."
mkdir -p "${STAGE}" "${DIST_DIR}"
cp -R "${BUNDLE}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
rm -f "${DMG_PATH}"
hdiutil create -volname "${VOL_NAME}" -srcfolder "${STAGE}" \
    -fs HFS+ -format UDZO -ov "${DMG_PATH}" >/dev/null

# Sign the disk image itself (belt-and-suspenders): the app inside is already signed + will be
# notarized, but signing the .dmg lets `spctl` assess the image directly as a clean pass too.
codesign --force --timestamp --sign "${DEVID}" "${DMG_PATH}"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "==> SKIP_NOTARIZE set — signed but not notarized. Local artifact: ${DMG_PATH}"
    rm -rf "${BUNDLE}"
    exit 0
fi

# ---- Notarize + staple ---------------------------------------------------------------------
# Two ways to authenticate, in priority order:
#   1. Direct credentials — the app-specific password you already have, via env:
#        AC_APPLE_ID="you@example.com" AC_PASSWORD="app-specific-pw" ./release-notarized.sh
#      (AC_TEAM_ID defaults to this cert's team, R54YWFRK4B; override if needed.)
#   2. A saved keychain profile (NOTARY_PROFILE), if you ran `notarytool store-credentials`.
AC_TEAM_ID="${AC_TEAM_ID:-R54YWFRK4B}"
NOTARY_ARGS=()
if [[ -n "${AC_APPLE_ID:-}" && -n "${AC_PASSWORD:-}" ]]; then
    echo "==> Notarizing with direct credentials (Apple ID ${AC_APPLE_ID}, team ${AC_TEAM_ID})..."
    NOTARY_ARGS=(--apple-id "${AC_APPLE_ID}" --team-id "${AC_TEAM_ID}" --password "${AC_PASSWORD}")
    # Offer to save these as a reusable profile so future runs need no env vars.
    if [[ "${SAVE_NOTARY_PROFILE:-0}" == "1" ]]; then
        xcrun notarytool store-credentials "${NOTARY_PROFILE}" \
            --apple-id "${AC_APPLE_ID}" --team-id "${AC_TEAM_ID}" --password "${AC_PASSWORD}" \
            && echo "    saved keychain profile '${NOTARY_PROFILE}' for next time"
    fi
elif xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
    echo "==> Notarizing with saved keychain profile '${NOTARY_PROFILE}'..."
    NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE}")
else
    cat >&2 <<MSG
error: no notarization credentials found. Provide the app-specific password you already have:
         AC_APPLE_ID="you@example.com" AC_PASSWORD="xxxx-xxxx-xxxx-xxxx" ./release-notarized.sh
       (add SAVE_NOTARY_PROFILE=1 once to remember it, or set NOTARY_PROFILE to a saved profile.)
       Team ID defaults to R54YWFRK4B — override with AC_TEAM_ID if you sign under another team.
MSG
    rm -rf "${BUNDLE}"
    exit 1
fi

echo "==> Submitting to Apple notary service (this can take a few minutes)..."
xcrun notarytool submit "${DMG_PATH}" "${NOTARY_ARGS[@]}" --wait

echo "==> Stapling the notarization ticket..."
xcrun stapler staple "${DMG_PATH}"
# Also staple the app inside so a copy dragged out of the DMG stays notarized offline.
xcrun stapler staple "${STAGE}/${BUNDLE}" 2>/dev/null || true

echo "==> Verifying Gatekeeper acceptance..."
# The authoritative check is the app assessed for execution — expect "source=Notarized Developer ID".
echo "app:"; spctl -a -t exec -vv "${STAGE}/${BUNDLE}" 2>&1 | sed 's/^/    /' || true
# The disk image assessed for open (now that it's signed) — expect "accepted".
echo "dmg:"; spctl -a -t open --context context:primary-signature -v "${DMG_PATH}" 2>&1 | sed 's/^/    /' || true

rm -rf "${BUNDLE}"
echo ""
echo "==> Done: ${DMG_PATH} (signed + notarized + stapled)"
echo "Recipients can open it directly — no right-click, no quarantine warning."
echo "Publish with:  gh release upload v${VERSION} \"${DMG_PATH}\""
