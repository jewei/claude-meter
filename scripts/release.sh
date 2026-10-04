#!/usr/bin/env bash
# Build, sign, notarize, and publish a Claude Meter release. See docs/releasing.md.
#
# Usage: scripts/release.sh VERSION BUILD [--prepare-only]
#   VERSION         Marketing version, for example 4.0.0.
#   BUILD           CFBundleVersion. Must be greater than every sparkle:version in appcast.xml.
#   --prepare-only  Build and validate a candidate in build/release. Change no tracked file,
#                   publish nothing, and allow any branch.
#
# Environment:
#   NOTARY_PROFILE    notarytool Keychain profile (default: notarytool)
#   NOTARY_KEYCHAIN   Keychain that holds the profile (default: the Keychain search list)
#   SIGNING_IDENTITY  Developer ID identity or its SHA-1, for the DMG (default: the release one)

set -Eeuo pipefail
# Use the macOS tools first. GNU coreutils in PATH change the options of stat, sed, and date.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

readonly REPO=jewei/claude-meter TEAM_ID=4L4SS26L9J APP_NAME=ClaudeMeter
# Every 4.x item hides from installs below build 295 (3.0). Those 2.x installs update to the
# newest 3.x item first, which runs the 2.x migrations, and see 4.x on their next check.
readonly MINIMUM_UPDATE_BUILD=295
# 4.0 starts with fresh settings, so every 3.x install sees the update window and its notes
# instead of a silent automatic install. 4.x installs keep silent updates.
readonly MAJOR_START_BUILD=400

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT WORK="$ROOT/build/release"
readonly ARCHIVE="$WORK/$APP_NAME.xcarchive" APP="$WORK/export/$APP_NAME.app"
readonly SOURCE_PACKAGES="$ROOT/build/SourcePackages"
readonly SIGN_UPDATE="$SOURCE_PACKAGES/artifacts/sparkle/Sparkle/bin/sign_update"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Jewei Mak ($TEAM_ID)}"
NOTARY_ARGS=(--keychain-profile "${NOTARY_PROFILE:-notarytool}")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN"); fi
STEP="start"
PHASE="local"
FAILED_COMMAND=""

step() { STEP="$1"; printf '\n==> %s\n' "$1"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Runs on every exit. After a failure it names the step and says what is already public.
finish() {
    local status=$?
    if ((status == 0)); then return; fi
    printf '\nThe release stopped in step "%s" (exit %s).\n' "$STEP" "$status" >&2
    if [[ -n "$FAILED_COMMAND" ]]; then printf 'Failed: %s\n' "$FAILED_COMMAND" >&2; fi
    case "$PHASE" in
        local) echo "Nothing was published. Correct the cause and run the script again." ;;
        committing) echo "Tracked files, and maybe a local commit, changed. Run:" \
            "git tag -d $TAG 2>/dev/null; git reset --hard origin/main" ;;
        committed) echo "Commit and tag $TAG exist only on this Mac. See docs/releasing.md." ;;
        tagged) echo "Tag $TAG is on GitHub. The release and feed are not. See docs/releasing.md." ;;
        *) echo "The GitHub release is public, but the feed is not. Run: git push origin HEAD:main" \
            "(if main moved: git pull --no-rebase origin main, then push)" ;;
    esac >&2
}

require_clean_tree() {
    local changes
    changes="$(git status --porcelain --untracked-files=all)"
    [[ -z "$changes" ]] || die "The working tree has changes. Commit or remove them first."
}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }

# Prints the sorted "UUID (arch)" pairs of a binary or a dSYM.
debug_uuids() { xcrun dwarfdump --uuid "$1" | awk '{ print $2, $3 }' | sort; }

# Prints the body of the [Unreleased] section of CHANGELOG.md, without leading blank lines.
unreleased_notes() {
    awk '/^## \[Unreleased\]/ { on = 1; next }
        /^## \[/ && on { exit }
        on && (started || NF) { started = 1; print }' CHANGELOG.md
}

# Promotes [Unreleased] in CHANGELOG.md to VERSION and updates the compare links.
promote_changelog() {
    local base="https://github.com/$REPO/compare"
    awk -v heading="## [$VERSION] - $(date -u +%Y-%m-%d)" \
        -v links="[Unreleased]: $base/$TAG...HEAD\n[$VERSION]: $base/v$PREVIOUS_VERSION...$TAG" '
        /^## \[Unreleased\]/ && !promoted { print; print ""; print heading; promoted = 1; next }
        /^\[Unreleased\]:/ { print links; linked = 1; next }
        { print }
        END { if (!linked) print "\n" links }' CHANGELOG.md >"$WORK/CHANGELOG.md"
    mv "$WORK/CHANGELOG.md" CHANGELOG.md
}

# Mounts the DMG read-only and checks the copy that users install, then detaches it.
check_dmg_contents() {
    local mount="$WORK/mount" status=0
    mkdir -p "$mount"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$DMG"
    {
        [[ -L "$mount/Applications" ]] || die "The DMG has no Applications link."
        codesign --verify --deep --strict "$mount/$APP_NAME.app"
        xcrun stapler validate "$mount/$APP_NAME.app"
        spctl --assess --type execute "$mount/$APP_NAME.app"
    } || status=$?
    hdiutil detach -quiet "$mount"
    ((status == 0)) || die "The app inside the DMG failed its checks."
}

# Submits a file to Apple and waits. On rejection, prints Apple's log and stops.
notarize() {
    local result="$WORK/notary.json" status id
    xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait --output-format json \
        >"$result" || true
    status="$(plutil -extract status raw "$result" 2>/dev/null || echo "no response")"
    if [[ "$status" != "Accepted" ]]; then
        id="$(plutil -extract id raw "$result" 2>/dev/null || true)"
        if [[ -n "$id" ]]; then xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" >&2 || true; fi
        die "Apple did not accept ${1##*/} (status: $status)."
    fi
}

main() {
    if [[ $# -lt 2 || $# -gt 3 || (${3:-} != "" && $3 != "--prepare-only") ]]; then
        die "usage: scripts/release.sh VERSION BUILD [--prepare-only]"
    fi
    readonly VERSION="$1" BUILD="$2" PREPARE_ONLY="${3:+yes}" TAG="v$1"
    readonly DMG="$WORK/$APP_NAME-$1.dmg" DSYMS="$WORK/$APP_NAME-$1-$2.dSYMs.zip"
    trap 'FAILED_COMMAND="line $LINENO: $BASH_COMMAND"' ERR
    trap finish EXIT
    cd "$ROOT"

    step "Check preconditions"
    [[ "$VERSION" =~ ^4\.[0-9]+(\.[0-9]+)?$ ]] ||
        die "VERSION must be 4.x, such as 4.0.0. Decide the minimumUpdateVersion for a new major."
    [[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || die "BUILD must be a positive integer."
    require_clean_tree
    if [[ -z "$PREPARE_ONLY" ]]; then
        [[ "$(git branch --show-current)" == "main" ]] || die "Publish from the main branch."
        git fetch --quiet origin main
        [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] ||
            die "HEAD is not origin/main. Pull or push first."
        git rev-parse -q --verify "refs/tags/$TAG" >/dev/null &&
            die "Tag $TAG already exists on this Mac."
        local remote_status=0
        git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || remote_status=$?
        # 2 means "no such tag". Anything else is a network or login error, not an answer.
        ((remote_status == 2)) || {
            ((remote_status == 0)) && die "Tag $TAG already exists on GitHub."
            die "Could not ask GitHub for tag $TAG (git ls-remote exit $remote_status)."
        }
        gh auth status >/dev/null 2>&1 || die "Log in to GitHub first: gh auth login"
    fi
    local latest_build identities
    latest_build="$(sed -n 's|.*<sparkle:version>\([0-9]*\)</sparkle:version>.*|\1|p' appcast.xml |
        sort -n | tail -n 1)"
    ((BUILD > ${latest_build:-0})) ||
        die "BUILD $BUILD must be greater than $latest_build, the newest build in appcast.xml."
    # The newest release tag is the base of the CHANGELOG compare link. The feed can lose a
    # bad item, but tags keep the history.
    PREVIOUS_VERSION="$(git describe --tags --abbrev=0 --match 'v*')"
    PREVIOUS_VERSION="${PREVIOUS_VERSION#v}"
    SOURCE_COMMIT="$(git rev-parse HEAD)"
    if [[ ! -f CHANGELOG.md ]] || ! grep -q '^## \[Unreleased\]' CHANGELOG.md; then
        die "CHANGELOG.md needs a '## [Unreleased]' section with the release notes."
    fi
    NOTES="$(unreleased_notes)"
    [[ -n "${NOTES//[[:space:]]/}" ]] || die "The [Unreleased] section of CHANGELOG.md is empty."
    [[ "$NOTES" != *"]]>"* ]] || die "The release notes must not contain ']]>'."
    # Step 7 checks the app against this requirement. Compile it now, so a bad text stops the
    # release before the build and notarization, not after them.
    local requirement
    requirement="$(/usr/libexec/PlistBuddy -c "Print :ClaudeMeterUpdateRequirement" App/Info.plist)" ||
        die "App/Info.plist has no ClaudeMeterUpdateRequirement."
    csreq -r="$requirement" -t >/dev/null ||
        die "ClaudeMeterUpdateRequirement in App/Info.plist is not a valid code requirement."
    identities="$(security find-identity -v -p codesigning)"
    [[ "$identities" == *"$SIGNING_IDENTITY"* ]] ||
        die "The signing identity '$SIGNING_IDENTITY' is not in the Keychain."
    xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null ||
        die "notarytool cannot use its stored credentials. See docs/releasing.md."
    security find-generic-password -s "https://sparkle-project.org" -a ed25519 >/dev/null 2>&1 ||
        die "The Sparkle EdDSA private key is not in the login Keychain."
    echo "Releasing Claude Meter $VERSION (build $BUILD) after build $latest_build."

    step "Run make check"
    make check
    [[ -x "$SIGN_UPDATE" ]] || die "Sparkle's sign_update is missing at $SIGN_UPDATE."

    step "Archive and export with Developer ID"
    rm -rf "$WORK"
    mkdir -p "$WORK"
    xcodebuild archive -project ClaudeMeter.xcodeproj -scheme ClaudeMeter -configuration Release \
        -destination "generic/platform=macOS" -archivePath "$ARCHIVE" \
        -derivedDataPath "$WORK/DerivedData" -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
        -onlyUsePackageVersionsFromResolvedFile -quiet \
        MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD"
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/export" \
        -exportOptionsPlist scripts/ExportOptions.plist -quiet

    step "Notarize and staple the app"
    ditto -c -k --keepParent "$APP" "$WORK/$APP_NAME.zip"
    notarize "$WORK/$APP_NAME.zip"
    xcrun stapler staple "$APP"

    step "Create, sign, notarize, and staple the DMG"
    mkdir -p "$WORK/dmg"
    ditto "$APP" "$WORK/dmg/$APP_NAME.app"
    ln -s /Applications "$WORK/dmg/Applications"
    hdiutil create -quiet -volname "Claude Meter" -srcfolder "$WORK/dmg" -format UDZO "$DMG"
    codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"

    step "Sign the DMG for Sparkle"
    local attributes signature length
    attributes="$("$SIGN_UPDATE" "$DMG")"
    signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$attributes")"
    length="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$attributes")"
    [[ -n "$signature" && -n "$length" ]] || die "sign_update printed no signature: $attributes"

    step "Validate the artifacts"
    local details binary_uuids symbol_uuids
    codesign --verify --deep --strict --verbose=2 "$APP"
    # The app updates itself only when it meets this requirement (App/Sources/ReleaseSignature).
    # In `-R=text` the "=" marks inline text; another "=" would be a requirement syntax error.
    codesign --verify --strict -R="$(plist_value ClaudeMeterUpdateRequirement)" "$APP" ||
        die "The app does not meet its own update requirement, so it would never update."
    details="$(codesign -dv "$APP" 2>&1)"
    [[ "$details" == *"TeamIdentifier=$TEAM_ID"* ]] || die "The app is not signed by $TEAM_ID."
    spctl --assess --type execute --verbose=2 "$APP"
    xcrun stapler validate "$APP"
    codesign --verify --strict --verbose=2 "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    xcrun stapler validate "$DMG"
    "$SIGN_UPDATE" --verify "$DMG" "$signature"
    [[ "$(stat -f %z "$DMG")" == "$length" ]] || die "The DMG changed after the Sparkle signature."
    [[ "$(plist_value CFBundleShortVersionString) $(plist_value CFBundleVersion)" == \
        "$VERSION $BUILD" ]] || die "The app does not have version $VERSION ($BUILD)."
    binary_uuids="$(debug_uuids "$APP/Contents/MacOS/$APP_NAME")"
    symbol_uuids="$(debug_uuids "$ARCHIVE/dSYMs/$APP_NAME.app.dSYM")"
    [[ -n "$binary_uuids" && "$binary_uuids" == "$symbol_uuids" ]] ||
        die "The dSYM UUIDs do not match the app binary."
    check_dmg_contents
    ditto -c -k --keepParent "$ARCHIVE/dSYMs" "$DSYMS"

    step "Write the candidate feed"
    local description minimum_system
    description="$(awk -f scripts/changelog-to-html.awk <<<"$NOTES")"
    minimum_system="$(plist_value LSMinimumSystemVersion)"
    cat >"$WORK/item.xml" <<EOF
        <item>
            <title>Version $VERSION</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$minimum_system</sparkle:minimumSystemVersion>
            <sparkle:minimumUpdateVersion>$MINIMUM_UPDATE_BUILD</sparkle:minimumUpdateVersion>
            <sparkle:minimumAutoupdateVersion>$MAJOR_START_BUILD</sparkle:minimumAutoupdateVersion>
            <description><![CDATA[
$description
            ]]></description>
            <enclosure
                url="https://github.com/$REPO/releases/download/$TAG/$APP_NAME-$VERSION.dmg"
                sparkle:edSignature="$signature"
                length="$length"
                type="application/octet-stream"
            />
        </item>
EOF
    # Insert the new item above the newest item. Keep every existing item.
    awk -v item="$WORK/item.xml" '
        !done && (/^[[:space:]]*<item>/ || /<\/channel>/) {
            while ((getline line < item) > 0) print line
            done = 1
        }
        { print }' appcast.xml >"$WORK/appcast.xml"
    xmllint --noout "$WORK/appcast.xml"
    (($(grep -c '<item>' "$WORK/appcast.xml") == $(grep -c '<item>' appcast.xml) + 1)) ||
        die "The candidate feed does not have exactly one new item."
    require_clean_tree

    if [[ -n "$PREPARE_ONLY" ]]; then
        echo "Candidate ready in build/release (DMG, dSYMs, appcast.xml). Nothing was published."
        return
    fi

    step "Commit and tag the release"
    [[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] ||
        die "HEAD changed during the build. The DMG does not contain the new commit."
    PHASE="committing"
    cp "$WORK/appcast.xml" appcast.xml
    promote_changelog
    sed -i '' -E "s/^(MARKETING_VERSION = ).*/\1$VERSION/;s/^(CURRENT_PROJECT_VERSION = ).*/\1$BUILD/" \
        Config/Version.xcconfig
    git add appcast.xml CHANGELOG.md Config/Version.xcconfig
    git commit --quiet -m "Release $TAG"
    git tag -a "$TAG" -m "Claude Meter $VERSION"
    PHASE="committed"

    step "Publish the GitHub release"
    git push --quiet origin "refs/tags/$TAG"
    PHASE="tagged"
    printf '%s\n\n---\nDownload **%s**, open it, and drag Claude Meter to Applications.\n' \
        "$NOTES" "${DMG##*/}" >"$WORK/release-notes.md"
    gh release create "$TAG" "$DMG" "$DSYMS" --repo "$REPO" --verify-tag \
        --title "Claude Meter $VERSION" --notes-file "$WORK/release-notes.md"
    PHASE="released"

    # The feed goes live last, so no installed app sees an item whose DMG does not exist yet.
    step "Publish the feed"
    git push --quiet origin HEAD:main
    PHASE="done"
    echo "Released Claude Meter $VERSION: https://github.com/$REPO/releases/tag/$TAG"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
