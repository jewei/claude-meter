#!/usr/bin/env python3
"""Synthetic fixtures only: no GUI, public releases, credentials, or network."""

import copy
import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
from pathlib import Path
import tempfile
import sys
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

SPEC = importlib.util.spec_from_file_location("upgrade", Path(__file__).with_name("sparkle-upgrade.py"))
upgrade = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(upgrade)


def feed(version="2.17", build="200"):
    return f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:shortVersionString>{version}</sparkle:shortVersionString><sparkle:version>{build}</sparkle:version>
<enclosure url="https://github.com/jewei/claude-meter/releases/download/v{version}/ClaudeMeter-{version}.dmg"
sparkle:edSignature="synthetic-signature" length="100" /></item></channel></rss>'''.encode()


def report():
    return {"schema_version": 1, "status": "passed", "method": "sparkle",
            "previous_tag": "v2.16", "previous": {"version": "2.16", "build": "199"},
            "expected": upgrade.feed_expectation(feed(), "2.17", "200"),
            "installed": {"version": "2.17", "build": "200"},
            "checks": {key: True for key in upgrade.REQUIRED_CHECKS},
            "previous_dmg_sha256": "a" * 64, "previous_pid": 100,
            "launch": {"pid": 101, "seconds_observed": 5}, "started_at": 1000, "finished_at": 1020}


class ReportTests(unittest.TestCase):
    def test_accepts_complete_matching_report(self):
        upgrade.verify_report(report(), report()["expected"], "v2.16", 1000, 1020)

    def test_rejects_failed_incomplete_stale_or_wrong_release(self):
        mutations = [
            lambda r: r.update(status="failed"),
            lambda r: r.update(schema_version=True),
            lambda r: r.update(previous_pid=True),
            lambda r: r.update(method="manual-copy"),
            lambda r: r.update(previous_tag="v2.15"),
            lambda r: r["previous"].update(build="200"),
            lambda r: r["previous"].update(build=float("inf")),
            lambda r: r["installed"].update(build="201"),
            lambda r: r["expected"].update(feed_sha256="b" * 64),
            lambda r: r["expected"].update(signing_team="ANOTHERTEAM"),
            lambda r: r["launch"].update(pid=100),
            lambda r: r["launch"].update(seconds_observed=0),
            lambda r: r["launch"].update(seconds_observed=float("inf")),
            lambda r: r.update(started_at=999),
            lambda r: r.update(finished_at=2000),
            lambda r: r.pop("installed"),
        ]
        mutations += [lambda r, key=key: r["checks"].update({key: False}) for key in upgrade.REQUIRED_CHECKS]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                changed = copy.deepcopy(report())
                mutate(changed)
                with self.assertRaises(upgrade.CheckFailed):
                    upgrade.verify_report(changed, report()["expected"], "v2.16", 1000, 1020)

    def test_feed_must_name_exact_target(self):
        for data in [b"not xml", feed(build="201"), feed().replace(b"synthetic-signature", b""),
                     feed().replace(b"github.com", b"example.test")]:
            with self.assertRaises(upgrade.CheckFailed):
                upgrade.feed_expectation(data, "2.17", "200")

    def test_report_io_rejects_special_files_links_and_large_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report"
            upgrade.write_report(path, report())
            self.assertEqual(json.loads(upgrade.read_bounded(path)), report())
            with self.assertRaises(upgrade.CheckFailed):
                upgrade.read_bounded(path, 1)
            link = Path(directory) / "link"
            link.symlink_to(path)
            with self.assertRaises(OSError):
                upgrade.read_bounded(link)
            fifo = Path(directory) / "fifo"
            os.mkfifo(fifo)
            with self.assertRaises(upgrade.CheckFailed):
                upgrade.read_bounded(fifo)


class ProcessDetectionTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "macOS process format")
    def test_exact_process_path_with_spaces_and_long_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory).resolve() / ("long-directory-" * 8) / "Test App.app"
            executable = app / "Contents/MacOS/ClaudeMeter"
            executable.parent.mkdir(parents=True)
            # A minimal local executable tests lookup without launching Claude Meter.
            # Copying Apple's platform-signed sleep binary changes its signing context.
            subprocess.run(["/usr/bin/clang", "-x", "c", "-o", str(executable), "-"],
                           input=b"#include <unistd.h>\nint main(void) { sleep(10); return 0; }\n",
                           capture_output=True, check=True, timeout=30)
            process = subprocess.Popen([str(executable)])
            try:
                self.assertEqual(upgrade.wait_for_launch(app, 2), process.pid)
                self.assertEqual(upgrade.matching_pids(app), {process.pid})
                self.assertEqual(upgrade.matching_pids(app.parent / "Other.app"), set())
            finally:
                process.terminate()
                process.wait(timeout=2)


class LiveFlowFixtures(unittest.TestCase):
    def test_previous_app_is_the_only_installed_copy_and_result_requires_relaunch(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            args = types.SimpleNamespace(version="2.17", build="200", previous_tag="v2.16",
                isolated_user="fixture", team=upgrade.TEAM_ID, report=str(home / "report.json"),
                wait_seconds=2)
            copied = []
            launches = []

            def write_app(app, version, build):
                (app / "Contents").mkdir(parents=True, exist_ok=True)
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": upgrade.BUNDLE_ID,
                    "CFBundleShortVersionString": version, "CFBundleVersion": build}))

            def fake_download(url, path, limit):
                if url == upgrade.FEED_URL:
                    path.write_bytes(feed())
                else:
                    self.assertTrue(url.endswith("/v2.16/ClaudeMeter-2.16.dmg"))
                    path.write_bytes(b"synthetic previous disk image")

            def fake_command(command, timeout=60):
                if command[:2] == ["/usr/bin/hdiutil", "attach"]:
                    mount = Path(command[command.index("-mountpoint") + 1])
                    write_app(mount / "ClaudeMeter.app", "2.16", "199")
                elif command[0] == "/usr/bin/ditto":
                    copied.append(command[1:])
                    shutil.copytree(command[1], command[2])
                return b""

            def fake_launch(app, timeout, excluded=()):
                launches.append(excluded)
                if not excluded:
                    # Stand-in for Sparkle replacement after the old app launches.
                    write_app(app, "2.17", "200")
                    return 100
                return 101

            with patch.object(upgrade, "isolated_home", return_value=home), \
                 patch.object(upgrade, "download", side_effect=fake_download), \
                 patch.object(upgrade, "command", side_effect=fake_command), \
                 patch.object(upgrade, "verify_app") as signature_check, \
                 patch.object(upgrade, "wait_for_launch", side_effect=fake_launch), \
                 patch.object(upgrade, "matching_pids", return_value={101}), \
                 patch.object(upgrade.time, "sleep"):
                upgrade.run_live(args)
            recorded = json.loads(upgrade.read_bounded(args.report))
            upgrade.verify_report(recorded, report()["expected"], "v2.16")
            self.assertEqual(len(copied), 1)
            self.assertIn("mount/ClaudeMeter.app", copied[0][0])
            self.assertEqual(launches, [(), [100]])
            self.assertEqual(signature_check.call_count, 2)



class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.remote = self.root / "origin.git"
        self.project = self.root / "project"
        # Git fixtures must never read or execute the user's global config/hooks.
        template = self.root / "empty-template"
        template.mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                           GIT_TEMPLATE_DIR=str(template))
        isolated_environment = patch.dict(os.environ, environment, clear=True)
        isolated_environment.start()
        self.addCleanup(isolated_environment.stop)
        upgrade.command(["git", "init", "--bare", str(self.remote)])
        upgrade.command(["git", "init", "-b", "main", str(self.project)])
        self.git("config", "user.name", "Release fixture")
        self.git("config", "user.email", "fixture@example.test")
        self.git("config", "commit.gpgsign", "false")
        self.git("remote", "add", "origin", str(self.remote))
        (self.project / "appcast.xml").write_bytes(feed("2.16", "199"))
        self.git("add", "appcast.xml")
        self.git("commit", "-m", "previous release")
        self.previous = self.git("rev-parse", "HEAD").decode().strip()
        (self.project / "appcast.xml").write_bytes(feed())
        self.git("commit", "-am", "new release")
        self.release = self.git("rev-parse", "HEAD").decode().strip()
        self.git("push", "origin", "HEAD:main")
        self.report_path = self.root / "upgrade.json"
        self.args = types.SimpleNamespace(project=str(self.project), previous_commit=self.previous,
            previous_tag="v2.16", version="2.17", build="200", team=upgrade.TEAM_ID,
            report=str(self.report_path), feed=str(self.project / "appcast.xml"),
            not_before=1000, wait_seconds=0)

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        return upgrade.command(["git", "-C", str(self.project), *args])

    def remote_feed(self):
        return upgrade.command(["git", "--git-dir", str(self.remote), "show", "main:appcast.xml"])

    def test_failure_restores_only_feed_and_preserves_later_commits_and_local_changes(self):
        (self.project / "source.txt").write_text("later source change")
        self.git("add", "source.txt")
        self.git("commit", "-m", "later source change")
        self.git("push", "origin", "HEAD:main")
        (self.project / "source.txt").write_text("uncommitted user work")
        failed = report()
        failed["status"] = "failed"
        upgrade.write_report(self.report_path, failed)
        with self.assertRaises(upgrade.CheckFailed):
            upgrade.complete_release(self.args)
        self.assertEqual(self.remote_feed(), feed("2.16", "199"))
        self.assertEqual((self.project / "source.txt").read_text(), "uncommitted user work")
        remote_source = upgrade.command(["git", "--git-dir", str(self.remote), "show", "main:source.txt"])
        self.assertEqual(remote_source, b"later source change")

    def test_nonfinite_report_triggers_recovery(self):
        # JSON accepts numeric overflow even when named Infinity is disabled.
        self.report_path.write_text(json.dumps(report()).replace('"199"', '1e400'))
        with self.assertRaises(upgrade.CheckFailed):
            upgrade.complete_release(self.args)
        self.assertEqual(self.remote_feed(), feed("2.16", "199"))

    def test_nonfinite_launch_duration_triggers_recovery(self):
        self.report_path.write_text(json.dumps(report()).replace(
            '"seconds_observed": 5', '"seconds_observed": 1e400'))
        with self.assertRaises(upgrade.CheckFailed):
            upgrade.complete_release(self.args)
        self.assertEqual(self.remote_feed(), feed("2.16", "199"))

    def test_missing_report_cannot_complete_release(self):
        with self.assertRaises(upgrade.CheckFailed):
            upgrade.complete_release(self.args)
        self.assertEqual(self.remote_feed(), feed("2.16", "199"))

    def test_recovery_refuses_to_overwrite_a_newer_feed(self):
        (self.project / "appcast.xml").write_bytes(feed("2.18", "201"))
        self.git("commit", "-am", "another release")
        self.git("push", "origin", "HEAD:main")
        with self.assertRaises(upgrade.CheckFailed):
            upgrade.recover_feed(self.project, self.previous, feed())
        self.assertEqual(self.remote_feed(), feed("2.18", "201"))

    def test_upload_failure_keeps_verified_feed_and_staging_branch(self):
        upgrade.write_report(self.report_path, report())
        with patch.object(upgrade, "command", side_effect=upgrade.CheckFailed("upload failed")) as called:
            with self.assertRaises(upgrade.CheckFailed):
                upgrade.complete_release(self.args)
        self.assertEqual(called.call_count, 1)
        self.assertEqual(self.remote_feed(), feed())

    def test_success_uploads_evidence_before_removing_staging_branch(self):
        upgrade.write_report(self.report_path, report())
        with patch.object(upgrade, "command", return_value=b"") as called:
            upgrade.complete_release(self.args)
        calls = [item.args[0] for item in called.call_args_list]
        self.assertEqual(calls[0][:3], ["gh", "release", "upload"])
        self.assertIn("--delete", calls[1])
        self.assertEqual(self.remote_feed(), feed())


if __name__ == "__main__":
    unittest.main(verbosity=2)
