import os
import time
import unittest
from datetime import datetime
from unittest.mock import patch

from run import screenshot_clock, validate_environment


class EnvironmentTests(unittest.TestCase):
    approved = {"xcode": "Xcode 27.1\nBuild version 27A9275",
                "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                "deviceType": "approved-model"}

    def test_clock_pins_ipad_date_and_local_time_across_runner_timezones(self):
        for zone in ("UTC", "Asia/Shanghai", "America/Los_Angeles"):
            try:
                with self.subTest(zone=zone), patch.dict(os.environ, {"TZ": zone}):
                    time.tzset()
                    clock = datetime.fromisoformat(screenshot_clock()).astimezone()
                    self.assertEqual(clock.strftime("%Y-%m-%d %H:%M %A"), "2022-01-01 09:41 Saturday")
                    self.assertIsNotNone(clock.utcoffset())
                    self.assertIn(":00.000", screenshot_clock())
            finally:
                time.tzset()

    def test_xcode_27_0_is_compatible_for_iphone_and_ipad(self):
        for profile in ("iphone", "ipad"):
            validate_environment(profile, {**self.approved, "xcode": "Xcode 27.0\nBuild version 27A266a"}, self.approved)

    def test_other_toolchains_and_duo_still_require_approval(self):
        for profile, xcode in (("iphone", "Xcode 28.0"), ("iphone-duo", "Xcode 27.0")):
            with self.assertRaisesRegex(RuntimeError, "approved Xcode"):
                validate_environment(profile, {**self.approved, "xcode": xcode}, self.approved)

    def test_simulator_changes_are_rejected(self):
        for key in ("runtime", "deviceType"):
            with self.assertRaisesRegex(RuntimeError, "Pinned simulator"):
                validate_environment("iphone", {**self.approved, key: "different"}, self.approved)
