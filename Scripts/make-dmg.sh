#!/bin/bash
#
# Builds a signed disk image around an already-notarised app bundle.
#
#     ./Scripts/make-dmg.sh "build/Build/Products/Release/Centered Volume.app" Centered-Volume.dmg

set -euo pipefail

# Resolve the arguments against the caller's directory before moving to the
# repository root, so relative paths mean what the caller meant by them.
APP_PATH="${1:?usage: make-dmg.sh <app path> <dmg path>}"
DMG_PATH="${2:?usage: make-dmg.sh <app path> <dmg path>}"
[ "${APP_PATH#/}" = "$APP_PATH" ] && APP_PATH="$PWD/$APP_PATH"
[ "${DMG_PATH#/}" = "$DMG_PATH" ] && DMG_PATH="$PWD/$DMG_PATH"

cd "$(dirname "$0")/.."

# Usable standalone as well as from sign-and-notarize.sh, which has already
# sourced these.
if [ -z "${DEVELOPER_ID_CERTIFICATE:-}" ] && [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi
: "${DEVELOPER_ID_CERTIFICATE:?DEVELOPER_ID_CERTIFICATE is not set}"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: app not found at ${APP_PATH}" >&2
    exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# ditto, not cp: it preserves the extended attributes and the stapled
# notarisation ticket that the signature is checked against.
ditto "$APP_PATH" "$STAGING/$(basename "$APP_PATH")"
ln -s /Applications "$STAGING/Applications"

# The copy is what ships, so verify that copy rather than the original.
codesign -vvv --deep --strict "$STAGING/$(basename "$APP_PATH")"

VOLNAME="$(basename "$APP_PATH" .app)"

rm -f "$DMG_PATH"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG_PATH"

# The disk image carries its own signature and, later, its own notarisation
# ticket. Gatekeeper checks the image when it is opened and the app when the
# copy dragged out of it is launched, so both need one.
codesign --force --sign "${DEVELOPER_ID_CERTIFICATE}" --timestamp "$DMG_PATH"

echo "wrote $DMG_PATH"
