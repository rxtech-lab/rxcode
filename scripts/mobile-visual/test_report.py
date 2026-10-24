import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
from unittest.mock import patch
import zipfile

import report
import run as runner


class Assets(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = []

    def handle_starttag(self, tag, attrs):
        for key, value in attrs:
            if key in ("src", "href"):
                self.paths.append(value)


class ReportTests(unittest.TestCase):
    def test_failure_archive_contains_all_relative_assets_and_device_filters(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "output"
            baselines = root / "baselines"
            profiles = list(report.LABELS)
            for profile in profiles:
                (output / profile).mkdir(parents=True)
                (baselines / profile).mkdir(parents=True)
                for screen in report.SCREENS:
                    (output / profile / f"{screen}.png").write_bytes(b"latest")
                    (baselines / profile / f"{screen}.png").write_bytes(b"approved")
                (output / profile / "settings-diff.png").write_bytes(b"difference")
                (output / profile / "xcodebuild.log").write_text("failed assertion")
            report.finish_report(output, profiles, baselines, "failed", ["<script>alert('bad')</script>"])
            html = (output / "review.html").read_text()
            self.assertNotIn("<script>alert('bad')</script>", html)
            self.assertIn("&lt;script&gt;", html)
            for profile in profiles:
                self.assertIn(f'value="{profile}"', html)
                self.assertIn(f'data-profile="{profile}"', html)
            self.assertIn("card.hidden =", html)
            assets = Assets()
            assets.feed(html)
            with zipfile.ZipFile(output / "mobile-visual-failure.zip") as archive:
                for asset in assets.paths:
                    self.assertIn(asset, archive.namelist())
                self.assertNotIn("mobile-visual-failure.zip", archive.namelist())
                self.assertEqual(archive.read("baselines/iphone/settings.png"), b"approved")
            # Regenerating after a CI failure must not nest the previous ZIP.
            report.finish_report(output, profiles, baselines, "failed")
            with zipfile.ZipFile(output / "mobile-visual-failure.zip") as archive:
                self.assertNotIn("mobile-visual-failure.zip", archive.namelist())

    def test_missing_screenshots_still_produce_a_diagnostic_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            report.finish_report(output, ["iphone-duo"], Path(temporary) / "baselines", "failed", ["Build failed"])
            self.assertIn("Latest screenshot unavailable", (output / "review.html").read_text())
            self.assertTrue((output / "mobile-visual-failure.zip").exists())

    def test_missing_approval_fails_and_packages_before_running_xcode(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"
            with patch.object(runner, "BASELINES", Path(temporary) / "missing"), patch(
                "sys.argv", ["run.py", "compare", "--profile", "iphone", "--output", str(output)]
            ), patch.object(runner, "run") as command:
                with self.assertRaisesRegex(RuntimeError, "No approved baseline"):
                    runner.main()
                command.assert_not_called()
            self.assertEqual(json.loads((output / "result.json").read_text())["status"], "failed")
            with zipfile.ZipFile(output / "mobile-visual-failure.zip") as archive:
                self.assertIn("error.txt", archive.namelist())
                self.assertIn("review.html", archive.namelist())

    def test_report_does_not_change_approved_images(self):
        with tempfile.TemporaryDirectory() as temporary:
            baseline = Path(temporary) / "baselines/iphone/settings.png"
            baseline.parent.mkdir(parents=True)
            baseline.write_bytes(b"approved original")
            before = hashlib.sha256(baseline.read_bytes()).hexdigest()
            report.finish_report(Path(temporary) / "output", ["iphone"], baseline.parents[1], "passed")
            self.assertEqual(hashlib.sha256(baseline.read_bytes()).hexdigest(), before)
            self.assertFalse((Path(temporary) / "output/mobile-visual-failure.zip").exists())

    def test_xcode_failure_preserves_partial_captures_logs_and_failure_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "output"

            def fail_build(options, profiles, destination):
                folder = destination / "iphone"
                folder.mkdir()
                (folder / "xcodebuild.log").write_text("XCTest assertion failed")
                (folder / "settings.png").write_bytes(b"partial capture")
                raise subprocess.CalledProcessError(65, ["xcodebuild", "test"])

            with patch.object(runner, "execute", side_effect=fail_build), patch(
                "sys.argv", ["run.py", "compare", "--profile", "iphone", "--output", str(output)]
            ):
                with self.assertRaises(subprocess.CalledProcessError):
                    runner.main()
            with zipfile.ZipFile(output / "mobile-visual-failure.zip") as archive:
                self.assertEqual(archive.read("iphone/settings.png"), b"partial capture")
                self.assertIn("iphone/xcodebuild.log", archive.namelist())
                self.assertIn("review.html", archive.namelist())
                self.assertEqual(json.loads(archive.read("result.json"))["status"], "failed")


if __name__ == "__main__":
    unittest.main()
