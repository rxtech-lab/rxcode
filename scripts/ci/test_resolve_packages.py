import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("resolve-packages.sh")


class PackageResolutionTests(unittest.TestCase):
    def resolve(self, message, failures):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / "xcodebuild"
            fake.write_text('''#!/bin/bash
echo "$*" >> "$CALLS"
count=$(wc -l < "$CALLS")
if [ "$count" -le "$FAILURES" ]; then
  echo "$FAILURE_MESSAGE"
  exit 74
fi
''')
            fake.chmod(0o755)
            sleep = root / "sleep"
            sleep.write_text('#!/bin/bash\nexit 0\n')
            sleep.chmod(0o755)
            calls = root / "calls"
            result = subprocess.run(
                ["bash", str(SCRIPT), "-project", "Project With Spaces.xcodeproj", "-scheme", "RxCodeMobile"],
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "CALLS": str(calls),
                     "FAILURES": str(failures), "FAILURE_MESSAGE": message},
                capture_output=True, text=True,
            )
            return result, calls.read_text().splitlines()

    def test_success_resolves_once(self):
        result, calls = self.resolve("", 0)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(calls, ["-resolvePackageDependencies -project Project With Spaces.xcodeproj -scheme RxCodeMobile"])

    def test_timed_out_download_recovers(self):
        result, calls = self.resolve("failed downloading binary: The request timed out.", 1)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(calls), 2)

    def test_retries_are_bounded_and_preserve_failure(self):
        result, calls = self.resolve("failed downloading binary: The request timed out.", 5)
        self.assertEqual(result.returncode, 74)
        self.assertEqual(len(calls), 3)

    def test_invalid_package_does_not_retry(self):
        result, calls = self.resolve("package product missing from manifest", 5)
        self.assertEqual(result.returncode, 74)
        self.assertEqual(len(calls), 1)

    def test_permanent_download_failure_does_not_retry(self):
        result, calls = self.resolve("failed downloading binary: HTTP 404", 5)
        self.assertEqual(result.returncode, 74)
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
