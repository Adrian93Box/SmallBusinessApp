#!/bin/bash
set -euo pipefail

echo "🚀 Starting App Store Connect Upload process for Small Business..."

load_env_file() {
    local file="$1" key value
    [ -f "$file" ] || return 0
    while IFS='=' read -r key value || [ -n "$key" ]; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// }" ]] && continue
        key="$(echo "$key" | xargs)"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        value="${value%\"}"; value="${value#\"}"
        value="${value%'}"; value="${value#'}"
        if [ -z "${!key:-}" ]; then
            export "$key=$value"
        fi
    done < "$file"
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
load_env_file "$REPO_ROOT/secrets/tokens.env"
load_env_file "$HOME/.appstoreconnect/tokens.env"

: "${ASC_KEY_ID:?Missing ASC_KEY_ID (environment, secrets/tokens.env or ~/.appstoreconnect/tokens.env)}"
: "${ASC_ISSUER_ID:?Missing ASC_ISSUER_ID (environment, secrets/tokens.env or ~/.appstoreconnect/tokens.env)}"
: "${ASC_TEAM_ID:=T77JR9H9SB}"

KEY_FILE="${ASC_PRIVATE_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
if [ ! -f "$KEY_FILE" ] && [ -f "$PWD/secrets/AuthKey_${ASC_KEY_ID}.p8" ]; then
    KEY_FILE="$PWD/secrets/AuthKey_${ASC_KEY_ID}.p8"
fi

if [ ! -f "$KEY_FILE" ]; then
    echo "❌ Error: API Key file $KEY_FILE not found!"
    exit 1
fi
export ASC_KEY_ID ASC_ISSUER_ID ASC_TEAM_ID

BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/GLSmallBusiness.xcarchive"
EXPORT_PATH="$BUILD_DIR/exported"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

mkdir -p "$BUILD_DIR"

cat <<PLIST > "$EXPORT_OPTIONS"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>T77JR9H9SB</string>
    <key>manageAppVersionAndBuildNumber</key>
    <true/>
</dict>
</plist>
PLIST

echo "🔍 Reading current build version..."
BUILD_VERSION=$(xcodebuild -showBuildSettings -project GLSmallBusiness.xcodeproj -configuration Release 2>/dev/null | grep 'CURRENT_PROJECT_VERSION =' | awk '{print $3}' | head -n 1)
echo "📦 Build Version: $BUILD_VERSION"

echo "📦 Archiving Small Business..."
xcodebuild clean archive \
    -project GLSmallBusiness.xcodeproj \
    -scheme GLSmallBusiness \
    -destination "generic/platform=iOS" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_FILE" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    -quiet

echo "📦 Exporting the .ipa..."
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_FILE" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    -quiet

IPA_PATH=$(find "$EXPORT_PATH" -name "*.ipa" | head -n 1)

if [ -z "$IPA_PATH" ]; then
    echo "❌ Error: .ipa file not found!"
    exit 1
fi

echo "🚀 Uploading Small Business to App Store Connect intake..."
xcrun altool --upload-app \
    -f "$IPA_PATH" \
    -t ios \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID"

echo "✅ Binary uploaded. Initiating automatic push to TestFlight..."
python3 "$SCRIPT_DIR/distribute_testflight.py" --app mb --version "$BUILD_VERSION" --key-id "$ASC_KEY_ID" --issuer-id "$ASC_ISSUER_ID" --key-path "$KEY_FILE"
