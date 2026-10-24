import unittest

from run import validate_environment


class EnvironmentTests(unittest.TestCase):
    approved = {"xcode": "Xcode 27.1\nBuild version 27A9275",
                "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                "deviceType": "approved-model"}

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
