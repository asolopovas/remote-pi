"""Offline installer isolation tests: python3 scripts/test-installers.py."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class IsolationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        self.log = self.work / 'calls'
        self.env = {**os.environ, 'HOME': str(self.work),
                    'PATH': f'{self.bin}:/usr/bin:/bin', 'CALLS': str(self.log),
                    'REMOTE_PI_PACKAGE': '', 'COCKPIT_REPO': '', 'COCKPIT_VERSION': ''}
        for command in ('curl', 'npm', 'node', 'pi', 'sudo', 'systemctl', 'launchctl'):
            self.mock(command, 'echo "$0 $*" >> "$CALLS"; exit 97')

    def mock(self, command, body):
        path = self.bin / command
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def run_shell(self, script, **env):
        return subprocess.run(['/bin/bash', '-euo', 'pipefail', '-c', script], cwd=self.work,
                              env={**self.env, **env}, text=True, capture_output=True, check=False)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ''

    def test_installer_defaults_and_invalid_destinations_fail_before_activity(self):
        for path, variable, values in (
            ('pi-extension/install.sh', 'REMOTE_PI_PACKAGE',
             ['', 'https://evil.test/pkg', '-flag', '../remote-pi', 'pkg@latest', 'pkg;echo bad']),
            ('cockpit/install-server.sh', 'COCKPIT_REPO',
             ['', 'https://github.com/owner/repo', 'owner/../repo', 'owner/repo?x', 'owner/repo#x']),
        ):
            for value in values:
                with self.subTest(path=path, value=value):
                    result = self.run_shell(f'bash "{ROOT / path}"', **{variable: value})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('error:', result.stderr)
                    self.assertEqual(self.calls(), '')
        result = self.run_shell(f'bash "{ROOT / "cockpit/install-server.sh"}"',
                                COCKPIT_REPO='independent/releases', COCKPIT_VERSION='../bad')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), '')
        self.assertFalse((self.work / '.local').exists())

    def test_extension_explicit_scoped_package_is_used_for_install_and_lookup(self):
        self.mock('npm', 'echo "$HOME/global"')
        self.mock('pi', '''echo "$*" >> "$CALLS"
mkdir -p "$HOME/.pi/agent/npm/node_modules/@independent/plugin/dist"
touch "$HOME/.pi/agent/npm/node_modules/@independent/plugin/dist/index.js"''')
        self.mock('node', 'echo 1.0.0')
        source = (ROOT / 'pi-extension/install.sh').read_text().removesuffix('main "$@"\n')
        result = self.run_shell(source + '\nensure_plugin\n', REMOTE_PI_PACKAGE='@independent/plugin')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), 'install npm:@independent/plugin\n')
        self.assertIn('@independent/plugin', result.stdout)

    def test_cockpit_explicit_repo_and_checksum_failure(self):
        self.mock('curl', '''echo "$*" >> "$CALLS"
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then shift; out="$1"; fi
  shift
done
case "$out" in
  *SHA256SUMS) printf '%064d  cockpit-server-1.2.3-linux-x86_64.zip\\n' 0 > "$out" ;;
  *) echo corrupt > "$out" ;;
esac''')
        self.mock('uname', 'case "$1" in -s) echo Linux;; -m) echo x86_64;; esac')
        result = self.run_shell(f'bash "{ROOT / "cockpit/install-server.sh"}"',
                                COCKPIT_REPO='independent/releases', COCKPIT_VERSION='1.2.3')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum mismatch', result.stderr)
        self.assertIn('https://github.com/independent/releases/releases/download/', self.calls())
        self.assertNotIn('jacobaraujo7', self.calls())
        self.assertNotIn('Installing', result.stdout)


if __name__ == '__main__':
    unittest.main()
