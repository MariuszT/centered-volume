#!/bin/bash

set -eu

cd "$(dirname "$0")/.."

# Load environment variables
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
else
    echo "Error: .env file not found"
    exit 1
fi

# Fail before the (multi-minute) build rather than after it, and with a
# message that names the missing variable instead of a stray "App not found"
# or a notarytool auth error.
required_vars=(APP_NAME DEVELOPER_ID_CERTIFICATE APPLE_TEAM_ID APPLE_ID APPLE_APP_SPECIFIC_PASSWORD)
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "Error: ${var} is not set in .env" >&2
        exit 1
    fi
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
BINARY_PRODUCTS_DIR="build/Build/Products/Release"
BUILD_DIR="$BINARY_PRODUCTS_DIR"
APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"

# notarytool exits 0 even when Apple returns "Invalid", so the status has to be
# read back explicitly. Without this the script sails on to staple a ticket
# that was never issued, and only the staple failure hints at what went wrong.
notarize() {
    local path="$1" json status submission_id
    json="$(xcrun notarytool submit "${path}" \
        --apple-id "${APPLE_ID}" \
        --team-id "${APPLE_TEAM_ID}" \
        --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
        --wait --output-format json)"
    status="$(printf '%s' "$json" | plutil -extract status raw -o - -)"
    submission_id="$(printf '%s' "$json" | plutil -extract id raw -o - -)"
    echo "Notarization of $(basename "${path}"): ${status} (submission ${submission_id})"
    if [ "${status}" != "Accepted" ]; then
        echo -e "${RED}Error: notarization failed for ${path}${NC}" >&2
        xcrun notarytool log "${submission_id}" \
            --apple-id "${APPLE_ID}" \
            --team-id "${APPLE_TEAM_ID}" \
            --password "${APPLE_APP_SPECIFIC_PASSWORD}" >&2 || true
        exit 1
    fi
}

echo -e "${BLUE}=== Building App ===${NC}"
# CODE_SIGN_STYLE=Manual: the project is set to automatic signing, which
# refuses a manually specified CODE_SIGN_IDENTITY. Developer ID needs no
# provisioning profile here, so the specifier is cleared rather than left to
# automatic resolution.
# OTHER_CODE_SIGN_FLAGS: notarisation requires a secure timestamp on the
# signature. Xcode applies one for Developer ID by default; asking for it
# explicitly makes the release independent of that default.
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: the "build" action injects
# com.apple.security.get-task-allow so a debugger can attach. Apple rejects
# notarisation of anything carrying it, so a distribution build must not have
# it. The project's own entitlements file is empty, so nothing else is lost.
xcodebuild -project CenteredVolume.xcodeproj \
    -scheme CenteredVolume \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath build \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${DEVELOPER_ID_CERTIFICATE}" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    clean build

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Error: App not found at ${APP_PATH}${NC}"
    exit 1
fi

echo -e "${BLUE}=== Verifying Signature ===${NC}"
# xcodebuild already signed the app with the entitlements from the project;
# re-signing here with codesign --force and no --entitlements would silently
# drop them. Trust the build's signature and only verify it.
codesign -vvv --deep --strict "${APP_PATH}"

echo -e "${BLUE}=== Creating Archive ===${NC}"
cd "${BUILD_DIR}"
ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.zip"
cd - > /dev/null

echo -e "${BLUE}=== Submitting for Notarization ===${NC}"
notarize "${ZIP_PATH}"

echo -e "${BLUE}=== Stapling Notarization ===${NC}"
xcrun stapler staple "${APP_PATH}"

echo -e "${BLUE}=== Verifying Notarization ===${NC}"
# -t exec, not -t install: this evaluates an .app, not an installer package.
spctl -a -vvv -t exec "${APP_PATH}"

echo -e "${BLUE}=== Building DMG ===${NC}"
DMG_PATH="${BUILD_DIR}/Centered-Volume.dmg"
./Scripts/make-dmg.sh "${APP_PATH}" "${DMG_PATH}"

echo -e "${BLUE}=== Notarizing DMG ===${NC}"
# The app inside is already notarised and stapled; the image needs its own
# ticket because Gatekeeper checks the image when it is opened and the app
# when the copy dragged out of it is launched.
notarize "${DMG_PATH}"

echo -e "${BLUE}=== Stapling DMG ===${NC}"
xcrun stapler staple "${DMG_PATH}"

echo -e "${BLUE}=== Verifying DMG ===${NC}"
spctl -a -vvv -t open --context context:primary-signature "${DMG_PATH}"

echo -e "${GREEN}=== Success! ===${NC}"
echo -e "Notarized app: ${APP_PATH}"
echo -e "Notarized DMG: ${DMG_PATH}"
