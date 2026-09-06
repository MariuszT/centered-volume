#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="CenteredVolume.xcodeproj"
SCHEME="CenteredVolume"
CONFIGURATION="Release"
DERIVED_DATA_PATH="build/DerivedData"
ARCHIVE_PATH="build/AppStore/CenteredVolume.xcarchive"
EXPORT_PATH="build/AppStore/Export"
EXPORT_OPTIONS_PLIST="build/AppStore/ExportOptions.plist"

# No baked-in default: this is a public repo, and a hardcoded team ID here
# would silently sign someone else's build for our team.
TEAM_ID="${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"

mkdir -p "build/AppStore"

echo "==> Archiving for Mac App Store"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  archive

cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF

echo "==> Exporting archive for App Store Connect"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -allowProvisioningUpdates

echo "==> Done"
echo "Exported artifacts are in: $EXPORT_PATH"
echo "Upload from Xcode Organizer or with Transporter."
