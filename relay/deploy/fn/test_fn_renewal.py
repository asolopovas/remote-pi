"""Offline failure/retry regressions using real deployment scripts and fake commands."""
import os
import pathlib
import subprocess
import tempfile
import unittest

DIRECTORY = pathlib.Path(__file__).resolve().parent


class FnRenewalTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        (self.root / "acme-production/work").mkdir(parents=True)
        self.marker = self.root / "acme-production/work/deploy-required"
        self.log = self.root / "calls"
        self.copy_script("renew.sh")
        self.stub("certbot.sh", '''#!/bin/sh
set -eu
echo certbot >> calls
if [ "$ISSUE" != 0 ]; then
    touch acme-production/work/deploy-required
    rm -f aging-pending
fi
exit "${ACME_FAIL:-0}"
''')
        self.stub("deploy-certificate.sh", '''#!/bin/sh
set -eu
echo deploy >> calls
[ ! -f aging-pending ] || exit 1
exit "${DEPLOY_FAIL:-0}"
''')
        self.stub("check.sh", '''#!/bin/sh
set -eu
echo "check $*" >> calls
if [ "${1:-}" = --wait-for-deployment ]; then exit "${POST_FAIL:-0}"; fi
exit "${CHECK_FAIL:-0}"
''')

    def copy_script(self, name):
        source = (DIRECTORY / name).read_text()
        source = source.replace("/opt/remote-pi-relay", str(self.root))
        source = source.replace("/run/lock/remote-pi-relay-acme.lock", str(self.root / "lock"))
        self.stub(name, source)

    def stub(self, name, source):
        if name not in {"renew.sh", "certbot.sh", "deploy-certificate.sh", "check.sh"}:
            raise ValueError("Unknown fixture script")
        path = (self.root / name).resolve()
        if not path.is_relative_to(self.root):
            raise ValueError("Fixture path escaped temporary directory")
        path.write_text(source)
        path.chmod(0o700)

    def run_renewal(self, **values):
        environment = {**os.environ, "ISSUE": "0", **values}
        return subprocess.run(
            ["sh", str(self.root / "renew.sh")], env=environment,
            capture_output=True, text=True, timeout=10,
        )

    def test_failed_deploy_is_retried_after_no_new_issuance_check(self):
        first = self.run_renewal(ISSUE="1", DEPLOY_FAIL="1")
        self.assertNotEqual(first.returncode, 0)
        self.assertTrue(self.marker.exists())
        self.assertEqual(self.log.read_text().splitlines(), ["certbot", "deploy", "check "])
        self.log.write_text("")
        retry = self.run_renewal()
        self.assertEqual(retry.returncode, 0, retry.stderr)
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.log.read_text().splitlines(), [
            "certbot", "deploy", "check --wait-for-deployment", "check ",
        ])

    def test_failed_post_check_keeps_marker_for_retry(self):
        first = self.run_renewal(ISSUE="1", POST_FAIL="1")
        self.assertNotEqual(first.returncode, 0)
        self.assertTrue(self.marker.exists())
        retry = self.run_renewal()
        self.assertEqual(retry.returncode, 0, retry.stderr)
        self.assertFalse(self.marker.exists())

    def test_aging_pending_cannot_block_successful_issuance_and_deploy(self):
        self.marker.touch()
        (self.root / "aging-pending").touch()
        result = self.run_renewal(ISSUE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.marker.exists())
        self.assertFalse((self.root / "aging-pending").exists())
        self.assertEqual(self.log.read_text().splitlines(), [
            "certbot", "deploy", "check --wait-for-deployment", "check ",
        ])

    def test_acme_failure_does_not_mask_unresolved_pending_deploy(self):
        self.marker.touch()
        result = self.run_renewal(ACME_FAIL="1", DEPLOY_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.marker.exists())
        self.assertEqual(self.log.read_text().splitlines(), ["certbot", "deploy", "check "])

    def test_acme_failure_still_installs_valid_pending_but_reports_failure(self):
        self.marker.touch()
        result = self.run_renewal(ACME_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.log.read_text().splitlines(), [
            "certbot", "deploy", "check --wait-for-deployment", "check ",
        ])

    def test_final_check_failure_returns_nonzero(self):
        result = self.run_renewal(CHECK_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log.read_text().splitlines(), ["certbot", "check "])

    def test_wrong_but_unexpired_served_certificate_fails_bounded_check(self):
        self.copy_script("check.sh")
        (self.root / "acme-production/config/live/173.208.50.216").mkdir(parents=True)
        (self.root / "acme-production/config/live/173.208.50.216/fullchain.pem").write_text("intended")
        commands = self.root / "bin"
        commands.mkdir()
        # Fake crypto preserves bytes: this tests exact matching and retry logic,
        # not cryptography (public trust is checked separately against fn).
        (commands / "openssl").write_text('''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
if args[0] == 's_client':
    print(os.environ['SERVED_CERT'])
elif '-out' in args:
    data = pathlib.Path(args[args.index('-in') + 1]).read_bytes().strip()
    pathlib.Path(args[args.index('-out') + 1]).write_bytes(data)
''')
        (commands / "curl").write_text("#!/bin/sh\necho OK\n")
        (commands / "sleep").write_text("#!/bin/sh\necho retry >> \"$RETRY_LOG\"\n")
        for path in commands.iterdir():
            path.chmod(0o700)
        environment = {
            **os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
            "RETRY_LOG": str(self.log), "SERVED_CERT": "old-but-unexpired",
        }
        failed = subprocess.run(
            ["sh", str(self.root / "check.sh"), "--wait-for-deployment"],
            env=environment, capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("exact production certificate verification failed", failed.stderr)
        self.assertEqual(self.log.read_text().splitlines(), ["retry"] * 14)
        environment["SERVED_CERT"] = "intended"
        retry = subprocess.run(
            ["sh", str(self.root / "check.sh"), "--wait-for-deployment"],
            env=environment, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(retry.returncode, 0, retry.stderr)


if __name__ == "__main__":
    unittest.main()
