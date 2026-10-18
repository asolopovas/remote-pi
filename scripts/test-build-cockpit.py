"""Offline macOS wrapper regressions; no real SDK, build or install is invoked."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNNER = '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\\n')
if name in ('find', 'sed'):
    sys.exit(97)
if name == os.environ.get('FAIL_RUNNER') and (not os.environ.get('FAIL_ARG') or os.environ['FAIL_ARG'] in args):
    sys.exit(23)
if name == 'ditto':
    import shutil
    shutil.copytree(*args)
'''


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.root = self.work / 'repo with spaces'
        (self.root / 'scripts').mkdir(parents=True)
        self.script = self.root / 'scripts/build-cockpit.sh'
        shutil.copy2(ROOT / 'scripts/build-cockpit.sh', self.script)
        self.cli = self.root / 'cockpit/cli/target/release/cockpit'
        self.cli.parent.mkdir(parents=True)
        self.cli.write_text('new CLI')
        self.app = self.root / 'cockpit/build/macos/Build/Products/Release/Cockpit.app'
        self.app.mkdir(parents=True)
        (self.app / 'artifact').write_text('new app')
        self.home = self.work / 'home'
        for name, content in (
                ('.cockpit/bin/cockpit', 'old CLI'),
                ('Applications/Cockpit.app/artifact', 'old app'),
                ('.pub-cache/package/create_framework_symlinks.sh', "cut -d '-' -f 1 -f 3"),
                ('.pub-cache/package/colors.dart', 'const Color.from(alpha: 1)')):
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        (self.home / '.cockpit/bin/ck').symlink_to('cockpit')
        # An ephemeral plugin path can itself point into the shared cache.
        plugin = self.root / 'cockpit/macos/Flutter/ephemeral/.symlinks/plugins/media_kit_libs_macos_video/macos'
        plugin.parent.mkdir(parents=True)
        plugin.symlink_to(self.home / '.pub-cache/package')
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        for name in ('cargo', 'flutter', 'zig', 'codesign', 'ditto', 'find', 'sed'):
            path = self.bin / name
            path.write_text(RUNNER)
            path.chmod(0o755)
        self.log = self.work / 'calls'
        self.env = {**os.environ, 'HOME': str(self.home),
                    'PATH': f'{self.bin}:/usr/bin:/bin', 'CALLS': str(self.log)}
        self.before = self.snapshot(self.home)

    def snapshot(self, directory):
        return {str(p.relative_to(directory)): (p.lstat().st_mode,
                os.readlink(p) if p.is_symlink() else p.read_bytes() if p.is_file() else None)
                for p in directory.rglob('*')}

    def run_build(self, *args, **env):
        result = subprocess.run(['/bin/bash', str(self.script), *args], cwd=self.work,
                                env={**self.env, **env}, text=True, capture_output=True)
        try:
            calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        except (OSError, ValueError) as error:
            self.fail(f'Invalid fake-runner log: {error}')
        self.assertFalse(any(call[0] in ('find', 'sed') for call in calls))
        self.assertEqual(self.snapshot(self.home / '.pub-cache'),
                         {key.removeprefix('.pub-cache/'): value for key, value in self.before.items()
                          if key.startswith('.pub-cache/')})
        return result, calls

    def test_default_build_does_not_install(self):
        result, calls = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(self.home), self.before)
        self.assertEqual([c[0] for c in calls], ['cargo', 'cargo', 'flutter', 'flutter', 'codesign'])
        self.assertIn(['flutter', 'build', 'macos'], calls)

    def test_failures_never_install(self):
        for runner, arg in (('cargo', 'build'), ('cargo', 'test'), ('flutter', 'get'),
                            ('flutter', 'macos'), ('codesign', '--verify')):
            with self.subTest(runner=runner, arg=arg):
                self.log.unlink(missing_ok=True)
                result, calls = self.run_build('--install', FAIL_RUNNER=runner, FAIL_ARG=arg)
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertEqual(calls[-1][0], runner)
                self.assertEqual(self.snapshot(self.home), self.before)

    def test_missing_app_never_installs(self):
        try:
            shutil.rmtree(self.app)
        except OSError as error:
            self.fail(f'Could not remove synthetic app: {error}')
        result, _ = self.run_build('--install')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Built app not found', result.stderr)
        self.assertEqual(self.snapshot(self.home), self.before)

    def test_explicit_install_and_custom_destination(self):
        for custom in (False, True):
            with self.subTest(custom=custom):
                dest = self.work / 'custom apps' if custom else self.home / 'Applications'
                result, calls = self.run_build('--install', *(('--dest', str(dest)) if custom else ()))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((dest / 'Cockpit.app/artifact').read_text(), 'new app')
                if not custom:
                    self.assertEqual((dest / 'Cockpit.app.bak/artifact').read_text(), 'old app')
                cli = self.home / '.cockpit/bin/cockpit'
                self.assertEqual(cli.read_text(), 'new CLI')
                try:
                    executable = os.access(cli, os.X_OK)
                except OSError as error:
                    self.fail(f'Could not inspect synthetic CLI: {error}')
                self.assertTrue(executable)
                self.assertEqual(os.readlink(cli.with_name('ck')), 'cockpit')
                self.assertEqual(calls[-1][0], 'ditto')
                self.assertIn('codesign', [call[0] for call in calls])

    def test_invalid_arguments_do_nothing(self):
        for args in (('--dest',), ('--dest', ''), ('--dest', '--install'),
                     ('--dest', str(self.work / 'apps')), ('--unknown',)):
            with self.subTest(args=args):
                result, calls = self.run_build(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Error:' if args[0] == '--dest' else 'Unknown argument', result.stderr)
                self.assertEqual(calls, [])
                self.assertEqual(self.snapshot(self.home), self.before)


if __name__ == '__main__':
    unittest.main()
