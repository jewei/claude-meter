#!/usr/bin/env python3
"""Record a signed Sparkle upgrade in an isolated macOS desktop, then gate release completion."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import pwd
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET

REPOSITORY = "jewei/claude-meter"
BUNDLE_ID = "com.jewei.claudemeter"
TEAM_ID = "4L4SS26L9J"
FEED_URL = "https://raw.githubusercontent.com/jewei/claude-meter/main/appcast.xml"
MAX_REPORT_BYTES = 64 * 1024
REQUIRED_CHECKS = (
    "previous_signature", "previous_notarization", "previous_launch",
    "installed_signature", "installed_notarization", "version_and_build", "new_process_launch",
)


class CheckFailed(Exception):
    pass


def command(args, timeout=60):
    """Do not copy subprocess output into diagnostics; it can contain home paths."""
    try:
        result = subprocess.run(args, check=True, capture_output=True, timeout=timeout)
    except (subprocess.SubprocessError, OSError) as error:
        raise CheckFailed("Command failed: " + Path(args[0]).name) from error
    return result.stdout


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def read_bounded(path, limit=MAX_REPORT_BYTES):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > limit:
            raise CheckFailed("Expected a bounded regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            data = source.read(limit + 1)
        if len(data) != metadata.st_size or len(data) > limit:
            raise CheckFailed("File changed while reading")
        return data
    finally:
        os.close(descriptor)


def read_report(path):
    def reject_nonfinite(value):
        raise ValueError("Non-finite JSON number")
    def finite_float(value):
        number = float(value)
        if not math.isfinite(number):
            raise ValueError("Non-finite JSON number")
        return number
    return json.loads(read_bounded(path), parse_constant=reject_nonfinite, parse_float=finite_float)


def write_report(path, report):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as target:
        temporary = Path(target.name)
        json.dump(report, target, indent=2, sort_keys=True)
        target.write("\n")
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def release_values(version, build, previous_tag):
    if not re.fullmatch(r"\d+(?:\.\d+){1,3}", version):
        raise CheckFailed("Invalid expected version")
    if not re.fullmatch(r"[1-9]\d*", build):
        raise CheckFailed("Invalid expected build")
    if not re.fullmatch(r"v\d+(?:\.\d+){1,3}", previous_tag):
        raise CheckFailed("Invalid previous release tag")


def feed_expectation(data, version, build, team=TEAM_ID):
    try:
        root = ET.fromstring(data)
        item = root.find("./channel/item")
        fields = {child.tag.rsplit("}", 1)[-1]: child for child in item}
        enclosure = fields["enclosure"]
        signature = next(value for key, value in enclosure.attrib.items()
                         if key.rsplit("}", 1)[-1] == "edSignature")
        expected_url = f"https://github.com/{REPOSITORY}/releases/download/v{version}/ClaudeMeter-{version}.dmg"
        valid = (fields["shortVersionString"].text == version
                 and fields["version"].text == build
                 and enclosure.get("url") == expected_url and bool(signature))
    except (ET.ParseError, TypeError, KeyError, StopIteration) as error:
        raise CheckFailed("Invalid update feed") from error
    if not valid:
        raise CheckFailed("Update feed does not match the expected release")
    return {"version": version, "build": build, "feed_sha256": sha256(data), "signing_team": team}


def app_info(app):
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise CheckFailed("Unexpected application identity")
    return {"version": str(info["CFBundleShortVersionString"]),
            "build": str(info["CFBundleVersion"])}


def verify_app(app, team):
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    # codesign's display output is on stderr. Keep it local and extract only TeamIdentifier.
    result = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(app)],
                            capture_output=True, timeout=30, check=True)
    if f"TeamIdentifier={team}" not in result.stderr.decode("utf-8", errors="replace").splitlines():
        raise CheckFailed("Unexpected signing team")
    command(["/usr/bin/xcrun", "stapler", "validate", str(app)])
    command(["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)])


def matching_pids(app):
    binary = str(app / "Contents/MacOS/ClaudeMeter")
    output = command(["/bin/ps", "-ww", "-axo", "pid=,comm="]).decode("utf-8", errors="replace")
    return {int(parts[0]) for line in output.splitlines()
            if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == binary}


def wait_for_launch(app, timeout, excluded=()):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        candidates = matching_pids(app) - set(excluded)
        if candidates:
            return min(candidates)
        time.sleep(0.25)
    raise CheckFailed("The expected application process did not launch")


def isolated_home(expected_user):
    if sys.platform != "darwin" or os.getuid() == 0:
        raise CheckFailed("The live check requires a non-root macOS desktop")
    user = pwd.getpwuid(os.getuid())
    if user.pw_name != expected_user or os.stat("/dev/console").st_uid != os.getuid():
        raise CheckFailed("Run as the named isolated user in that user's active desktop")
    home = Path(user.pw_dir)
    forbidden = [*home.glob(".claude*"), home / ".codex", home / ".grok",
                 home / "Library/Application Support/Cursor"]
    if any(path.exists() or path.is_symlink() for path in forbidden):
        raise CheckFailed("Use a fresh test account without provider data")
    # Never replace an existing installation or stop another running app.
    process_list = command(["/bin/ps", "-ww", "-axo", "comm="]).decode("utf-8", errors="replace")
    if any(line.endswith("/ClaudeMeter.app/Contents/MacOS/ClaudeMeter") for line in process_list.splitlines()):
        raise CheckFailed("A Claude Meter process is already running")
    return home


def download(url, path, max_bytes):
    command(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
             "--proto", "=https", "--proto-redir", "=https", "--max-time", "120",
             "--max-filesize", str(max_bytes), "--output", str(path), url], timeout=130)
    if path.stat().st_size > max_bytes:
        raise CheckFailed("Download exceeds its byte limit")


def run_live(args):
    release_values(args.version, args.build, args.previous_tag)
    home = isolated_home(args.isolated_user)
    report_path = Path(args.report).resolve()
    if report_path.exists():
        raise CheckFailed("Use a new report path for each live check")
    report = {"schema_version": 1, "status": "failed", "started_at": time.time(),
              "previous_tag": args.previous_tag, "method": "sparkle", "checks": {}}
    run_dir = home / "Applications/ClaudeMeter Upgrade Tests" / uuid.uuid4().hex
    run_dir.mkdir(parents=True)
    app = run_dir / "ClaudeMeter.app"
    mounted = False
    deadline = time.monotonic() + args.wait_seconds
    try:
        feed = run_dir / "appcast.xml"
        # The raw GitHub feed can lag its branch update. Wait before opening Sparkle.
        while True:
            download(FEED_URL, feed, 4 * 1024 * 1024)
            try:
                report["expected"] = feed_expectation(
                    read_bounded(feed, 4 * 1024 * 1024), args.version, args.build, args.team)
                break
            except CheckFailed:
                if time.monotonic() >= deadline:
                    raise CheckFailed("The public feed did not reach the expected release")
                time.sleep(5)
        prior_version = args.previous_tag[1:]
        disk = run_dir / "previous.dmg"
        prior_url = f"https://github.com/{REPOSITORY}/releases/download/{args.previous_tag}/ClaudeMeter-{prior_version}.dmg"
        download(prior_url, disk, 256 * 1024 * 1024)
        report["previous_dmg_sha256"] = sha256(disk.read_bytes())
        mount = run_dir / "mount"
        mount.mkdir()
        command(["/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mount), str(disk)])
        mounted = True
        previous = mount / "ClaudeMeter.app"
        verify_app(previous, args.team)
        report["checks"].update(previous_signature=True, previous_notarization=True)
        report["previous"] = app_info(previous)
        if report["previous"]["version"] != prior_version or not report["previous"]["build"].isdigit():
            raise CheckFailed("The previous signed app does not match its release tag")
        if int(report["previous"]["build"]) >= int(args.build):
            raise CheckFailed("The expected build must be newer than the previous app")
        command(["/usr/bin/ditto", str(previous), str(app)])
        command(["/usr/bin/hdiutil", "detach", str(mount)])
        mounted = False
        # This account is dedicated to the check. Leave provider polling disabled.
        command(["/usr/bin/defaults", "write", BUNDLE_ID, "isActive", "-bool", "false"])
        command(["/usr/bin/open", "-n", str(app)])
        previous_pid = wait_for_launch(app, 20)
        report["previous_pid"] = previous_pid
        report["checks"]["previous_launch"] = True
        print("In the isolated desktop, select Check for Updates in Claude Meter Settings.", flush=True)
        print("Use Sparkle to install the update and relaunch. Do not copy a replacement app.", flush=True)
        while time.monotonic() < deadline:
            try:
                if app_info(app) == {"version": args.version, "build": args.build}:
                    break
            except (OSError, ValueError, KeyError):
                pass  # Sparkle can temporarily remove the old bundle during replacement.
            time.sleep(1)
        else:
            raise CheckFailed("Sparkle did not install the expected version and build before the deadline")
        report["installed"] = app_info(app)
        report["checks"]["version_and_build"] = True
        verify_app(app, args.team)
        report["checks"].update(installed_signature=True, installed_notarization=True)
        pid = wait_for_launch(app, 30, excluded=[previous_pid])
        time.sleep(5)
        if pid not in matching_pids(app) or previous_pid in matching_pids(app):
            raise CheckFailed("The updated app did not remain running after relaunch")
        report["launch"] = {"pid": pid, "seconds_observed": 5}
        report["checks"]["new_process_launch"] = True
        report["status"] = "passed"
    except (CheckFailed, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        report["error"] = str(error) if isinstance(error, CheckFailed) else "Live upgrade check failed"
        raise CheckFailed(report["error"]) from error
    finally:
        if mounted:
            try:
                command(["/usr/bin/hdiutil", "detach", str(run_dir / "mount")])
            except CheckFailed:
                pass
        report["finished_at"] = time.time()
        write_report(report_path, report)
    print("Signed Sparkle upgrade and relaunch passed. Report written.")


def verify_report(report, expected, previous_tag, not_before=0, now=None):
    now = time.time() if now is None else now
    try:
        valid = (
            type(report["schema_version"]) is int and report["schema_version"] == 1
            and report["status"] == "passed"
            and report["method"] == "sparkle" and report["previous_tag"] == previous_tag
            and report["expected"] == expected
            and report["previous"]["version"] == previous_tag[1:]
            and isinstance(report["previous"]["build"], str)
            and re.fullmatch(r"[1-9]\d*", report["previous"]["build"]) is not None
            and int(report["previous"]["build"]) < int(expected["build"])
            and report["installed"] == {key: expected[key] for key in ("version", "build")}
            and all(report["checks"][key] is True for key in REQUIRED_CHECKS)
            and re.fullmatch(r"[0-9a-f]{64}", report["previous_dmg_sha256"]) is not None
            and type(report["previous_pid"]) is int and type(report["launch"]["pid"]) is int
            and report["previous_pid"] > 0 and report["launch"]["pid"] > 0
            and report["launch"]["pid"] != report["previous_pid"]
            and math.isfinite(report["launch"]["seconds_observed"])
            and report["launch"]["seconds_observed"] >= 5
            and not_before <= report["started_at"] <= report["finished_at"] <= now + 60
        )
    except (KeyError, TypeError, ValueError, OverflowError):
        valid = False
    if not valid:
        raise CheckFailed("Upgrade report is failed, incomplete, stale, or for another release")


def recover_feed(project, previous_commit, expected_feed):
    """Restore only the prior feed, preserving later source commits and the caller's checkout."""
    previous = command(["git", "-C", str(project), "show", f"{previous_commit}:appcast.xml"])
    command(["git", "-C", str(project), "fetch", "origin", "main"])
    remote = command(["git", "-C", str(project), "rev-parse", "FETCH_HEAD"]).decode().strip()
    current = command(["git", "-C", str(project), "show", f"{remote}:appcast.xml"])
    if current != expected_feed:
        raise CheckFailed("The remote feed changed. Check it before restoring the previous feed")
    with tempfile.TemporaryDirectory(prefix="claude-meter-feed-recovery-") as directory:
        worktree = Path(directory) / "checkout"
        command(["git", "-C", str(project), "worktree", "add", "--detach", str(worktree), remote])
        try:
            (worktree / "appcast.xml").write_bytes(previous)
            command(["git", "-C", str(worktree), "add", "appcast.xml"])
            command(["git", "-C", str(worktree), "commit", "-m", "fix: restore update feed after failed upgrade check"])
            # A concurrent main update rejects this normal push. Never force the feed.
            command(["git", "-C", str(worktree), "push", "origin", "HEAD:main"])
        finally:
            command(["git", "-C", str(project), "worktree", "remove", "--force", str(worktree)])


def complete_release(args):
    release_values(args.version, args.build, args.previous_tag)
    project = Path(args.project).resolve()
    feed = read_bounded(args.feed, 4 * 1024 * 1024)
    expected = feed_expectation(feed, args.version, args.build, args.team)
    deadline = time.monotonic() + args.wait_seconds
    print("Waiting for the isolated desktop's upgrade report. Release completion is pending.", flush=True)
    try:
        while not Path(args.report).exists():
            if time.monotonic() >= deadline:
                raise CheckFailed("No upgrade report arrived before the release deadline")
            time.sleep(1)
        report = read_report(args.report)
        verify_report(report, expected, args.previous_tag, args.not_before)
    except (CheckFailed, OSError, ValueError, KeyboardInterrupt) as error:
        print("Upgrade verification failed. Restoring the previous update feed.", file=sys.stderr)
        recover_feed(project, args.previous_commit, feed)
        raise CheckFailed("Release verification failed; the previous update feed was restored") from error
    # Upload evidence before removing the staging branch or reporting release success.
    command(["gh", "release", "upload", f"v{args.version}", str(Path(args.report).resolve()),
             "--repo", REPOSITORY, "--clobber"])
    command(["git", "-C", str(project), "push", "origin", "--delete", f"release-staging/v{args.version}"])
    print("Signed upgrade report accepted and attached to the release.")


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="action", required=True)
    for name in ("run", "verify-report", "complete"):
        sub = commands.add_parser(name)
        sub.add_argument("--previous-tag", required=True)
        sub.add_argument("--version", required=True)
        sub.add_argument("--build", required=True)
        sub.add_argument("--report", required=True)
        sub.add_argument("--team", default=TEAM_ID)
        if name == "run":
            sub.add_argument("--isolated-user", required=True)
            sub.add_argument("--wait-seconds", type=int, default=600)
        else:
            sub.add_argument("--feed", required=True)
            sub.add_argument("--not-before", type=float, default=0)
        if name == "complete":
            sub.add_argument("--project", required=True)
            sub.add_argument("--previous-commit", required=True)
            sub.add_argument("--wait-seconds", type=int, default=900)
    return result


def main():
    args = parser().parse_args()
    try:
        if args.action == "run":
            run_live(args)
        elif args.action == "complete":
            complete_release(args)
        else:
            release_values(args.version, args.build, args.previous_tag)
            expected = feed_expectation(read_bounded(args.feed, 4 * 1024 * 1024), args.version, args.build, args.team)
            verify_report(read_report(args.report), expected, args.previous_tag, args.not_before)
            print("Upgrade report passed validation.")
    except (CheckFailed, OSError, ValueError) as error:
        message = str(error) if isinstance(error, CheckFailed) else "Could not read upgrade verification input"
        print("error: " + message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
