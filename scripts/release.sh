#!/usr/bin/env bash
# Usage: scripts/release.sh [version] [build]
#   version  e.g. 1.1   (default: reads MARKETING_VERSION from project)
#   build    e.g. 2     (default: git commit count — `git rev-list --count HEAD`)
#
# Prerequisites:
#   • Xcode with a valid Developer ID signing identity
#   • xcrun notarytool credentials stored: notarytool store-credentials "notarytool"
#   • gh CLI authenticated: gh auth login
#   • Project must build cleanly (Sparkle SPM package resolved)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$PROJECT_DIR/ClaudeMeter.xcodeproj"
SCHEME="ClaudeMeter"
APP_NAME="ClaudeMeter"
TEAM_ID="4L4SS26L9J"
APPLE_ID="jewei.mak@gmail.com"
KEYCHAIN_PROFILE="notarytool"
GITHUB_REPO="jewei/claude-meter"
MIN_MACOS="14.0"

# xcpretty is optional; without it the archive still succeeds.
run_xcodebuild() {
    if command -v xcpretty >/dev/null 2>&1; then
        xcodebuild "$@" | xcpretty --quiet
    else
        xcodebuild "$@"
    fi
}

# ── Version ───────────────────────────────────────────────────────────────────

read_build_setting() {
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -configuration Release -showBuildSettings 2>/dev/null \
        | awk -v key="$1" '$1 == key { print $3; exit }'
}

VERSION="${1:-$(read_build_setting MARKETING_VERSION)}"
# Build number defaults to the git commit count — monotonic by construction
# (the release commit guarantees it grows between releases) and reproducible.
# Sparkle compares this (CFBundleVersion → sparkle:version) to detect updates,
# so it must always increase. Pass an explicit arg to override.
BUILD="${2:-$(git -C "$PROJECT_DIR" rev-list --count HEAD)}"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
    echo "error: could not read version from project. Pass them as arguments." >&2
    exit 1
fi

DMG_NAME="$APP_NAME-$VERSION.dmg"
TAG="v$VERSION"

echo "▶ Releasing $APP_NAME $VERSION (build $BUILD)"

# ── Persist version into the project ──────────────────────────────────────────
# Write the release version/build back into project.pbxproj so the repo always
# reflects what shipped (and the no-arg default path stays correct next time).
# The archive below also passes these on the command line, so the baked
# Info.plist — and therefore the About tab — can never drift from the release.

PBXPROJ="$PROJECT/project.pbxproj"
sed -i '' -E "s/(MARKETING_VERSION = )[^;]*;/\1$VERSION;/g" "$PBXPROJ"
sed -i '' -E "s/(CURRENT_PROJECT_VERSION = )[^;]*;/\1$BUILD;/g" "$PBXPROJ"

# ── Changelog notes ───────────────────────────────────────────────────────────
# Capture the [Unreleased] section body now and fail fast if it's empty — no
# point building for ten minutes only to discover there are no release notes.
# The file itself is promoted to the new version only after the GitHub release
# succeeds (see "Promote changelog" below), matching the commit-last philosophy.

CHANGELOG="$PROJECT_DIR/CHANGELOG.md"
RELEASE_NOTES="$(awk '
    /^## \[Unreleased\]/ { capture = 1; next }
    /^## \[/ && capture  { exit }
    capture              { print }
' "$CHANGELOG" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba}')"

if [[ -z "${RELEASE_NOTES//[[:space:]]/}" ]]; then
    echo "error: CHANGELOG.md [Unreleased] section is empty — add release notes first." >&2
    exit 1
fi

# Previous tag, captured before any tag is created, for the changelog compare link.
PREV_TAG="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"

# ── Paths ─────────────────────────────────────────────────────────────────────

BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME-notarize.zip"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Locate sign_update ────────────────────────────────────────────────────────

SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" \
    -path "*/Sparkle/bin/sign_update" 2>/dev/null | grep -v old_dsa | head -1)
if [[ -z "$SIGN_UPDATE" ]]; then
    echo "error: Sparkle sign_update not found in DerivedData." >&2
    echo "       Build the project in Xcode at least once to resolve SPM packages." >&2
    exit 1
fi

# ── Archive ───────────────────────────────────────────────────────────────────

echo "▶ Archiving…"
run_xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    ONLY_ACTIVE_ARCH=NO

if [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo "error: archive failed — run with 'set -x' or check Xcode for details." >&2
    exit 1
fi

# ── Export ────────────────────────────────────────────────────────────────────

echo "▶ Exporting…"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

run_xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: export failed." >&2
    exit 1
fi

# ── Notarize ──────────────────────────────────────────────────────────────────

echo "▶ Zipping for notarization…"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "▶ Submitting to Apple notary service…"
xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "▶ Stapling…"
xcrun stapler staple "$APP_PATH"

# ── DMG ───────────────────────────────────────────────────────────────────────

echo "▶ Creating DMG…"
hdiutil create \
    -volname "Claude Meter" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO \
    "$DMG_PATH"

# ── Sign for Sparkle ──────────────────────────────────────────────────────────

echo "▶ Signing DMG for Sparkle…"
SIGN_OUTPUT=$("$SIGN_UPDATE" "$DMG_PATH")
SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
LENGTH=$(echo "$SIGN_OUTPUT"    | grep -o 'length="[^"]*"'              | cut -d'"' -f2)

echo "   edSignature: $SIGNATURE"
echo "   length:      $LENGTH"

# ── Update appcast.xml ────────────────────────────────────────────────────────

echo "▶ Updating appcast.xml…"
PUBDATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/$DMG_NAME"

cat > "$PROJECT_DIR/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Claude Meter</title>
        <link>https://raw.githubusercontent.com/$GITHUB_REPO/main/appcast.xml</link>
        <description>Claude Meter release feed</description>
        <language>en</language>
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
            <enclosure
                url="$DOWNLOAD_URL"
                sparkle:edSignature="$SIGNATURE"
                length="$LENGTH"
                type="application/octet-stream"
            />
        </item>
    </channel>
</rss>
XML

# ── GitHub Release ────────────────────────────────────────────────────────────
# Publish the release (with the DMG asset) BEFORE the appcast is pushed, so the
# Sparkle feed can never advertise a download URL that doesn't exist yet. If this
# step fails, the appcast was not pushed and the previous release stays live.

echo "▶ Creating GitHub release ${TAG}…"
gh release create "$TAG" "$DMG_PATH" \
    --repo "$GITHUB_REPO" \
    --title "Claude Meter $VERSION" \
    --notes "$RELEASE_NOTES

---
Download and open **$DMG_NAME** to install."

# ── Promote changelog ─────────────────────────────────────────────────────────
# The release now exists, so stamp [Unreleased] → [VERSION] - DATE, open a fresh
# empty Unreleased section above it, and refresh the compare links at the bottom.

echo "▶ Promoting CHANGELOG.md…"
TODAY="$(date -u '+%Y-%m-%d')"
if [[ -n "$PREV_TAG" ]]; then
    VERSION_LINK="[$VERSION]: https://github.com/$GITHUB_REPO/compare/$PREV_TAG...$TAG"
else
    VERSION_LINK="[$VERSION]: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
fi

CM_VERSION="$VERSION" CM_DATE="$TODAY" \
CM_UNREL="[Unreleased]: https://github.com/$GITHUB_REPO/compare/$TAG...HEAD" \
CM_VERLINK="$VERSION_LINK" \
perl -0pi -e '
    s{## \[Unreleased\]\n}{"## [Unreleased]\n\n## [$ENV{CM_VERSION}] - $ENV{CM_DATE}\n"}e;
    s{^\[Unreleased\]:.*$}{"$ENV{CM_UNREL}\n$ENV{CM_VERLINK}"}me;
' "$CHANGELOG"

# ── Commit & push ─────────────────────────────────────────────────────────────
# Done last: the appcast goes live to Sparkle only once the DMG is downloadable.

echo "▶ Committing version bump + changelog + appcast.xml…"
git -C "$PROJECT_DIR" add appcast.xml CHANGELOG.md ClaudeMeter.xcodeproj/project.pbxproj
git -C "$PROJECT_DIR" commit -m "Release $TAG"
git -C "$PROJECT_DIR" push

echo ""
echo "✓ Released Claude Meter $VERSION"
echo "  https://github.com/$GITHUB_REPO/releases/tag/$TAG"
