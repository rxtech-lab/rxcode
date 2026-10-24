import json
import unittest
from unittest.mock import patch

import prepare


class PreparationTests(unittest.TestCase):
    environment = {"xcode": "Xcode 27.1\nBuild version 27A9275",
                   "runtime": "approved-runtime", "deviceType": "approved-model"}

    def prepare_inventory(self, devices, available=True):
        inventory = {"runtimes": [{"identifier": "approved-runtime", "isAvailable": available}],
                     "devicetypes": [{"identifier": "approved-model"}],
                     "devices": {"approved-runtime": devices}}
        with patch.object(prepare, "read_json", return_value={"environment": self.environment}), patch.object(
            prepare.subprocess, "check_output", side_effect=[self.environment["xcode"], json.dumps(inventory)]
        ):
            prepare.prepare(["iphone"])

    @patch.object(prepare.subprocess, "run")
    def test_missing_device_is_created_with_exact_approved_model_and_runtime(self, run):
        self.prepare_inventory([])
        run.assert_called_once_with(["xcrun", "simctl", "create", "RxCode Visual iphone",
                                     "approved-model", "approved-runtime"], check=True)

    @patch.object(prepare.subprocess, "run")
    def test_existing_available_device_is_reused(self, run):
        self.prepare_inventory([{"isAvailable": True, "deviceTypeIdentifier": "approved-model"}])
        run.assert_not_called()

    @patch.object(prepare.subprocess, "run")
    def test_environment_mismatch_never_creates_a_substitute_device(self, run):
        with self.assertRaisesRegex(RuntimeError, "approved simulator runtime"):
            self.prepare_inventory([], available=False)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
