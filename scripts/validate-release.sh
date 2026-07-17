#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <ClaudeMeter.app> <ClaudeMeter.dmg> <appcast.xml>" >&2
    exit 2
fi

APP_PATH="$1"
DMG_PATH="$2"
APPCAST_PATH="$3"
WIDGET_PATH="$APP_PATH/Contents/PlugIns/ClaudeMeterWidgetExtension.appex"

for path in "$APP_PATH" "$DMG_PATH" "$APPCAST_PATH" "$WIDGET_PATH"; do
    if [[ ! -e "$path" ]]; then
        echo "error: missing release artifact: $path" >&2
        exit 1
    fi
done

echo "▶ Verifying signatures and notarization"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --strict --verbose=2 "$WIDGET_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

echo "▶ Verifying DMG integrity and mounted app"
hdiutil verify "$DMG_PATH"
MOUNT_DIR="$(mktemp -d)"
MOUNTED=0
cleanup() {
    if [[ "$MOUNTED" == "1" ]]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH" >/dev/null
MOUNTED=1
MOUNTED_APP="$MOUNT_DIR/ClaudeMeter.app"
if [[ ! -d "$MOUNTED_APP" ]]; then
    echo "error: ClaudeMeter.app is missing from the mounted DMG" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP"
xcrun stapler validate "$MOUNTED_APP"
spctl --assess --type execute --verbose=2 "$MOUNTED_APP"

echo "▶ Checking appcast metadata against local artifacts"
xml_value() {
    xmllint --xpath "string($1)" "$APPCAST_PATH"
}

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
FEED_VERSION="$(xml_value "//*[local-name()='shortVersionString']")"
FEED_BUILD="$(xml_value "//*[local-name()='version']")"
FEED_LENGTH="$(xml_value "//*[local-name()='enclosure']/@length")"
FEED_SIGNATURE="$(xml_value "//*[local-name()='enclosure']/@*[local-name()='edSignature']")"
FEED_URL="$(xml_value "//*[local-name()='enclosure']/@url")"
DMG_LENGTH="$(/usr/bin/stat -f '%z' "$DMG_PATH")"

[[ "$FEED_VERSION" == "$APP_VERSION" ]] || {
    echo "error: appcast version $FEED_VERSION does not match app version $APP_VERSION" >&2
    exit 1
}
[[ "$FEED_BUILD" == "$APP_BUILD" ]] || {
    echo "error: appcast build $FEED_BUILD does not match app build $APP_BUILD" >&2
    exit 1
}
[[ "$FEED_LENGTH" == "$DMG_LENGTH" ]] || {
    echo "error: appcast length $FEED_LENGTH does not match DMG length $DMG_LENGTH" >&2
    exit 1
}
[[ -n "$FEED_SIGNATURE" ]] || {
    echo "error: appcast Sparkle signature is empty" >&2
    exit 1
}
[[ "${FEED_URL##*/}" == "${DMG_PATH##*/}" ]] || {
    echo "error: appcast URL does not name ${DMG_PATH##*/}" >&2
    exit 1
}

echo "✓ Release artifacts passed local validation"
