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

echo -e "${BLUE}=== Building App ===${NC}"
xcodebuild -project CenteredVolume.xcodeproj \
    -scheme CenteredVolume \
    -configuration Release \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="${DEVELOPER_ID_CERTIFICATE}" \
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
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
xcrun notarytool submit "${ZIP_PATH}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_SPECIFIC_PASSWORD}" \
    --wait

echo -e "${BLUE}=== Stapling Notarization ===${NC}"
xcrun stapler staple "${APP_PATH}"

echo -e "${BLUE}=== Verifying Notarization ===${NC}"
# -t exec, not -t install: this evaluates an .app, not an installer package.
spctl -a -vvv -t exec "${APP_PATH}"

echo -e "${GREEN}=== Success! ===${NC}"
echo -e "Signed and notarized app: ${APP_PATH}"
echo -e "Archive: ${ZIP_PATH}"
