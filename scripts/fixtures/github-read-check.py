"""Exercise real subprocess retries without the network or a model call."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "github-read.py"


class GitHubReadTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.addCleanup(self.directory.cleanup)
        stub = self.root / "gh"
        stub.write_text("""#!/usr/bin/env python3
import os, pathlib, sys, time
count = pathlib.Path(os.environ['READ_COUNT'])
n = int(count.read_text()) + 1 if count.exists() else 1
count.write_text(str(n))
mode = os.environ['READ_MODE']
if mode == 'timeout':
    print('partial', flush=True)
    time.sleep(20)
if mode == 'fail' or (mode == 'recover' and n < 3):
    print('partial output that must never reach the caller')
    print('HTTP 502', file=sys.stderr)
    sys.exit(7)
print('complete response')
""")
        stub.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}",
                        READ_COUNT=str(self.root / "count"))

    def request(self, mode, *args):
        self.env["READ_MODE"] = mode
        # Production entry point with a short timeout and no test backoff delay.
        code = """import importlib.util, sys
spec = importlib.util.spec_from_file_location('github_read', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
sys.exit(module.read(sys.argv[2:], timeout=0.2, delays=(0, 0)))
"""
        return subprocess.run([sys.executable, "-c", code, str(HELPER), *args],
                              env=self.env, capture_output=True, text=True, timeout=5)

    def attempts(self):
        count = self.root / "count"
        return int(count.read_text()) if count.exists() else 0

    def test_transient_failure_discards_partial_output(self):
        result = self.request("recover", "pr", "diff", "https://example.invalid/pr/1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "complete response\n")
        self.assertEqual(self.attempts(), 3)

    def test_success_is_not_repeated(self):
        result = self.request("success", "pr", "view", "1", "--json", "headRefOid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.attempts(), 1)

    def test_exhaustion_preserves_failure_and_no_output(self):
        result = self.request("fail", "repo", "view", "owner/repo")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("HTTP 502", result.stderr)
        self.assertEqual(self.attempts(), 3)

    def test_hung_request_is_bounded(self):
        result = self.request("timeout", "pr", "diff", "1")
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.attempts(), 3)

    def test_merge_and_browser_are_refused_without_execution(self):
        for args in [("pr", "merge", "1"), ("pr", "view", "1", "--web")]:
            result = self.request("success", *args)
            self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.attempts(), 0)


if __name__ == "__main__":
    unittest.main()
