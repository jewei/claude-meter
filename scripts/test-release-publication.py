#!/usr/bin/env python3
"""Test release publication ordering without a network or signing credentials."""

import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("release.sh").read_text()
PUBLICATION = SCRIPT[SCRIPT.index("# ── Stage release commit"):]
NOTES = "### Fixed\n\n- Keep literal `code` and $(text)."
MOCKS = r'''
record() {
    printf '%s\n' "$1" >> "$PROJECT_DIR/events"
    [[ "$FAIL_AT" != "$1" ]]
}
git() {
    case "$*" in
        *"--delete release-staging/v2.17") record cleanup ;;
        *"push origin HEAD:main") record feed ;;
        *"push origin release-commit:refs/heads/release-staging/v2.17") record staging ;;
        *) return 99 ;;
    esac
}
gh() {
    [[ "$1 $2" == "release create" ]] || return 99
    record assets
}
'''


class PublicationTests(unittest.TestCase):
    def run_source_preflight(self, change="", prepare_only=False, after_preflight=""):
        with tempfile.TemporaryDirectory(prefix="release source ") as directory:
            root = Path(directory)
            script = root / "scripts" / "release.sh"
            script.parent.mkdir()
            (root / "CHANGELOG.md").write_text("## [Unreleased]\n\nFix usage.\n")
            (root / "appcast.xml").write_text(
                '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                '<sparkle:shortVersionString>2.17</sparkle:shortVersionString>'
                '<sparkle:version>10</sparkle:version></rss>'
            )
            (root / "source.swift").write_text("original\n")
            script.write_text(SCRIPT)

            def git(*args):
                return subprocess.run(
                    ["git", "-C", directory, *args], check=True,
                    capture_output=True, text=True, timeout=5,
                )

            git("init", "-b", "main")
            git("config", "user.email", "test@example.invalid")
            git("config", "user.name", "Release Test")
            git("add", ".")
            git("commit", "-m", "source")
            git("remote", "add", "origin", directory)
            if change in ("unstaged", "staged", "ahead"):
                (root / "source.swift").write_text("changed\n")
            if change in ("staged", "ahead"):
                git("add", "source.swift")
            if change == "ahead":
                git("switch", "-c", "candidate")
                git("commit", "-m", "candidate")
            if change == "untracked":
                (root / "extra.swift").write_text("untracked\n")
            prefix = SCRIPT[:SCRIPT.index("# ── Paths")]
            return subprocess.run(
                ["/bin/bash", "-c", "gh() { echo false; }\n" + prefix + after_preflight,
                 str(script), "2.18", "11", *(["--prepare-only"] if prepare_only else [])],
                capture_output=True, text=True, timeout=10,
            )

    def test_release_rejects_dirty_source(self):
        for change in ("unstaged", "staged", "untracked"):
            with self.subTest(change=change):
                result = self.run_source_preflight(change)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("clean worktree", result.stderr)

    def test_publishing_requires_fetched_main(self):
        result = self.run_source_preflight("ahead")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fetched origin/main", result.stderr)

    def test_clean_main_and_private_candidate_pass(self):
        for change, prepare in (("", False), ("ahead", True)):
            result = self.run_source_preflight(change, prepare)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_source_changes_during_preparation_are_rejected(self):
        changes = (
            'echo changed >> "$PROJECT_DIR/source.swift"',
            'git -C "$PROJECT_DIR" -c commit.gpgsign=false commit --allow-empty -m changed',
        )
        for change in changes:
            result = self.run_source_preflight(
                after_preflight="\n" + change + "\nrequire_release_source\n")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("error: release", result.stderr)
        self.assertIn('echo "▶ Archiving…"\nrequire_release_source', SCRIPT)
        self.assertIn(
            '"$SYMBOLS_PATH"\nrequire_release_source\n', SCRIPT)

    def run_publication(self, failure=""):
        with tempfile.TemporaryDirectory(prefix="release publication ") as directory:
            root = Path(directory)
            variables = {
                "PROJECT_DIR": directory,
                "BUILD_DIR": directory,
                "RELEASE_COMMIT": "release-commit",
                "TAG": "v2.17",
                "VERSION": "2.17",
                "DMG_PATH": str(root / "ClaudeMeter-2.17.dmg"),
                "DMG_NAME": "ClaudeMeter-2.17.dmg",
                "SYMBOLS_PATH": str(root / "symbols.zip"),
                "GITHUB_REPO": "test/repository",
                "RELEASE_NOTES": NOTES,
                "FAIL_AT": failure,
            }
            shell = "set -euo pipefail\n" + "".join(
                f"{key}={shlex.quote(value)}\n" for key, value in variables.items()
            ) + MOCKS + PUBLICATION
            result = subprocess.run(
                ["/bin/bash", "-c", shell], capture_output=True, text=True,
                timeout=5, env={"PATH": os.defpath},
            )
            events = (root / "events").read_text().splitlines()
            notes = root / "release-notes.md"
            return result, events, notes.read_text() if notes.exists() else None

    def test_success_publishes_assets_before_feed_and_removes_staging(self):
        result, events, notes = self.run_publication()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, ["staging", "assets", "feed", "cleanup"])
        self.assertIn("Released Claude Meter 2.17", result.stdout)
        self.assertEqual(
            notes, NOTES + "\n\n---\nDownload and open **ClaudeMeter-2.17.dmg** to install.\n"
        )

    def test_prepare_only_stops_before_repository_changes_and_publication(self):
        tail = SCRIPT[SCRIPT.index("# ── Stop after private preparation"):]
        result = subprocess.run(
            ["/bin/bash", "-c", "set -euo pipefail\nPREPARE_ONLY=1\nBUILD_DIR=private\n" + tail],
            capture_output=True, text=True, timeout=5, env={"PATH": os.defpath},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No publication performed", result.stdout)
        self.assertLess(SCRIPT.index("# ── Stop after private preparation"), SCRIPT.index("PBXPROJ="))
        self.assertIn('APPCAST_PATH="$BUILD_DIR/appcast.xml"', SCRIPT)
        self.assertIn('cat > "$APPCAST_PATH" <<XML', SCRIPT)

    def test_sparkle_signs_final_notarized_container_bytes(self):
        steps = [
            'codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"',
            'xcrun notarytool submit "$DMG_PATH"',
            'xcrun stapler staple "$DMG_PATH"',
            'SIGN_OUTPUT=$("$SIGN_UPDATE" "$DMG_PATH")',
            '"$SCRIPT_DIR/validate-release.sh"',
            '# ── Stop after private preparation',
        ]
        positions = [SCRIPT.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        validator = Path(__file__).with_name("validate-release.sh").read_text()
        self.assertIn('codesign --verify --strict --verbose=2 "$DMG_PATH"', validator)
        self.assertIn('xcrun stapler validate "$DMG_PATH"', validator)
        self.assertIn('spctl --assess --type open --context context:primary-signature', validator)

    def test_failure_stops_later_publication_steps(self):
        steps = ["staging", "assets", "feed", "cleanup"]
        for index, step in enumerate(steps):
            with self.subTest(step=step):
                result, events, _ = self.run_publication(step)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, steps[:index + 1])
                self.assertNotIn("Released Claude Meter", result.stdout)


if __name__ == "__main__":
    unittest.main()
