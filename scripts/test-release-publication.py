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
