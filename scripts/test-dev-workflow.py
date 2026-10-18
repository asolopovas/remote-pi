#!/usr/bin/env python3
"""Offline root workflow contract tests; every project runner is a fake."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NODE = shutil.which("node")
RUNNER = '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as stream:
    stream.write(json.dumps({'runner': name, 'args': args, 'cwd': os.getcwd(),
        'env': {k: v for k, v in os.environ.items() if k in (
            'HOME', 'USERPROFILE', 'REMOTE_PI_HOME', 'PI_CODING_AGENT_DIR',
            'XDG_CONFIG_HOME', 'CARGO_HOME', 'PUB_CACHE', 'GRADLE_USER_HOME',
            'PI_SUBAGENT_CHILD', 'DSA_EXEC', 'DSA_CALL', 'REMOTE_PI_MANAGED_CHILD',
            'REMOTE_PI_DIRECT_CONFIG', 'PI_CODING_AGENT_SESSION_DIR',
            'PI_ASYNC_NATIVE_RUNNER', 'NODE_OPTIONS', 'REMOTE_PI_RELAY',
            'CARGO_TARGET_DIR', 'CARGO_BUILD_TARGET', 'REMOTE_PI_TEST_RELAY_BINARY')}}) + '\\n')
if name == os.environ.get('FAIL_RUNNER') and (not os.environ.get('FAIL_ARG') or os.environ['FAIL_ARG'] in args):
    sys.exit(23)
'''


class FlutterAnalysisConfigTests(unittest.TestCase):
    def test_only_generated_build_is_excluded_from_source_analysis(self):
        config = (ROOT / 'app/analysis_options.yaml').read_text()
        self.assertIn('include: package:flutter_lints/flutter.yaml', config)
        analyzer = config.split('analyzer:\n', 1)[1].split('\nlinter:', 1)[0]
        self.assertEqual([line.split('#', 1)[0].strip() for line in analyzer.splitlines()
                          if line.strip()], ['exclude:', '- build/**'])


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='workflow-test-')
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.root = self.work / 'repo with spaces'
        (self.root / 'scripts').mkdir(parents=True)
        # Inject only into the disposable runner; production keeps /bin/bwrap.
        self.bwrap = self.work / 'synthetic-bwrap'
        self.bwrap.write_text('#!/bin/sh\nexit 0\n')
        self.bwrap.chmod(0o755)
        runner = (ROOT / 'scripts/validate.sh').read_text()
        self.assertIn('[[ -x /bin/bwrap ]]', runner)
        (self.root / 'scripts/validate.sh').write_text(
            runner.replace('[[ -x /bin/bwrap ]]', f'[[ -x {self.bwrap} ]]'))
        shutil.copy2(ROOT / 'Makefile', self.root / 'Makefile')
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        for name in ('node', 'flutter', 'cargo', 'pnpm-native', 'python3', 'git', 'bash'):
            file = self.bin / name
            file.write_text(RUNNER)
            file.chmod(0o755)
        self.home = self.work / 'real-home'
        self.home.mkdir()
        for name in ('.gradle/caches', '.gradle/wrapper/dists/gradle-8.14-all/cached/gradle-8.14/bin',
                     '.cargo/registry', '.cargo/git', '.pub-cache/hosted', '.pub-cache/hosted-hashes'):
            (self.home / name).mkdir(parents=True)
        (self.home / '.gradle/wrapper/dists/gradle-8.14-all/cached/gradle-8.14/bin/gradle').touch()
        for name in ('pi-extension/node_modules', 'pi-extension/build/managed-runtime', 'app/.dart_tool', 'app/android', 'relay'):
            (self.root / name).mkdir(parents=True)
        for name in ('pi-extension/build/managed-runtime/manifest.json', 'app/.dart_tool/package_config.json', 'app/android/gradlew'):
            (self.root / name).touch()
        (self.root / 'app/android/gradlew').chmod(0o755)
        self.log = self.work / 'calls'
        self.env = {**os.environ, 'PATH': f'{self.bin}:/usr/bin:/bin',
                    'HOME': str(self.home), 'TMPDIR': str(self.work),
                    'PNPM_NATIVE': str(self.bin / 'pnpm-native'), 'CALLS': str(self.log)}
        for key in ('CARGO_HOME', 'PUB_CACHE', 'GRADLE_USER_HOME', 'RUSTUP_HOME'):
            self.env.pop(key, None)
        self.env.update(dict.fromkeys((
            'DSA_EXEC', 'DSA_CALL', 'PI_SUBAGENT_CHILD', 'REMOTE_PI_MANAGED_CHILD',
            'REMOTE_PI_DIRECT_CONFIG', 'PI_CODING_AGENT_SESSION_DIR',
            'PI_ASYNC_NATIVE_RUNNER', 'NODE_OPTIONS', 'REMOTE_PI_RELAY'), 'must-not-inherit'))

    def run_workflow(self, *args, **env):
        self.log.unlink(missing_ok=True)
        return subprocess.run(['/bin/bash', str(self.root / 'scripts/validate.sh'), *args],
                              cwd=self.work, env={**self.env, **env},
                              text=True, capture_output=True, check=False)

    def calls(self):
        try:
            return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        except (OSError, ValueError) as error:
            self.fail(f'Invalid fake-runner log: {error}')

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS:', result.stdout)

    def test_invalid_arguments_run_nothing(self):
        for args in ((), ('invalid',), ('all', '--skip-tests'), ('--help',), ('tooling', 'all')):
            with self.subTest(args=args):
                result = self.run_workflow(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn('usage:', result.stderr)
                self.assertEqual(self.calls(), [])

    def test_tooling_requires_no_project_sdks(self):
        for name in ('node', 'flutter', 'cargo', 'pnpm-native'):
            (self.bin / name).unlink()
        self.assert_success(self.run_workflow('tooling'))
        calls = self.calls()
        self.assertEqual([c['args'] for c in calls], [
            ['scripts/test-dev-workflow.py'], ['scripts/test-deploy-android.py'], ['scripts/test-installers.py'],
            ['scripts/test-docker-publishers.py'], ['scripts/check-docs.py', '--self-test'],
            ['scripts/check-docs.py']])
        self.assertTrue(all(c['cwd'] == str(self.root) for c in calls))

    def test_full_order_cwd_and_offline_flags(self):
        self.assert_success(self.run_workflow('all'))
        calls = self.calls()
        for call in calls:
            name = call['runner']
            if name == 'node':  # Version preflight happens before HOME isolation.
                continue
            expected = {'cargo': 'relay', 'pnpm-native': 'pi-extension', 'flutter': 'app', 'bash': 'app'}.get(name)
            if name == 'python3' and call['args'] == ['scripts/test-launcher-pin-tty.py']:
                expected = 'pi-extension'
            self.assertEqual(call['cwd'], str(self.root / expected) if expected else str(self.root))
        cargo = [c['args'] for c in calls if c['runner'] == 'cargo']
        self.assertEqual(cargo, [['fmt', '--check'], ['clippy', '--offline', '--locked', '--', '-D', 'warnings'], ['test', '--offline', '--locked'], ['build', '--offline', '--locked', '--example', 'launch_fixture', '--target-dir', str(self.root / 'relay/target')]])
        pnpm = [c['args'] for c in calls if c['runner'] == 'pnpm-native']
        self.assertEqual(pnpm, [['--config.verify-deps-before-run=false', 'typecheck'], ['--config.verify-deps-before-run=false', 'build'], ['--config.verify-deps-before-run=false', 'exec', 'vitest', 'run', '--maxWorkers=1']])
        flutter = [c['args'] for c in calls if c['runner'] == 'flutter']
        self.assertEqual(flutter, [['analyze', '--no-pub'], ['test', '--no-pub', '--concurrency=1', 'test', 'test_acceptance/local_secure_launch_test.dart']])
        self.assertIn(['test/native/speech_to_text/run.sh'], [c['args'] for c in calls])

    def test_launch_is_focused_but_includes_real_integrations(self):
        self.assert_success(self.run_workflow('launch'))
        calls = self.calls()
        self.assertFalse(any(c['runner'] == 'bash' for c in calls))
        self.assertEqual([c['args'] for c in calls if c['runner'] == 'cargo'],
                         [['build', '--offline', '--locked', '--example', 'launch_fixture', '--target-dir', str(self.root / 'relay/target')]])
        vitest = next(c['args'] for c in calls if 'vitest' in c['args'])
        for name in ('src/session/launch_', 'src/session/managed_', 'src/session/secure_launcher.integration.test.ts', 'src/session/session_control'):
            self.assertIn(name, vitest)
        flutter = next(c['args'] for c in calls if c['runner'] == 'flutter')
        self.assertIn('test/agents/fresh_launcher_page_test.dart', flutter)
        self.assertIn('test_acceptance/local_secure_launch_test.dart', flutter)
        self.assertNotIn('analyze', flutter)
        self.assertIn('--no-pub', flutter)

    def test_native_fixture_build_and_execution_ignore_cargo_overrides(self):
        for mode in ('launch', 'all'):
            self.assert_success(self.run_workflow(
                mode, CARGO_TARGET_DIR=str(self.work / 'wrong-target'),
                CARGO_BUILD_TARGET='aarch64-unknown-linux-gnu'))
            calls = self.calls()
            build = next(c for c in calls if c['runner'] == 'cargo' and 'build' in c['args'])
            target = Path(build['args'][build['args'].index('--target-dir') + 1])
            self.assertEqual(target, self.root / 'relay/target')
            self.assertNotIn('CARGO_BUILD_TARGET', build['env'])
            flutter = next(c for c in calls if c['runner'] == 'flutter' and 'test' in c['args'])
            binary = str(target / 'debug/examples/launch_fixture')
            self.assertEqual(flutter['env']['REMOTE_PI_TEST_RELAY_BINARY'], binary)
            self.assertEqual(build['env']['REMOTE_PI_TEST_RELAY_BINARY'], binary)
            self.assertIn('test_acceptance/local_secure_launch_test.dart', flutter['args'])
        fixture = (ROOT / 'pi-extension/test/support/local-launch-host.mjs').read_text()
        self.assertIn('const relayBinary = process.env.REMOTE_PI_TEST_RELAY_BINARY;', fixture)
        self.assertIn('relay = spawn(relayBinary,', fixture)

    def test_native_acceptance_is_outside_default_flutter_discovery(self):
        acceptance = ROOT / 'app/test_acceptance/local_secure_launch_test.dart'
        self.assertTrue(acceptance.is_file())
        self.assertFalse((ROOT / 'app/test/integration/local_secure_launch_test.dart').exists())
        self.assertFalse(any('local-launch-host.mjs' in p.read_text()
                             for p in (ROOT / 'app/test').rglob('*_test.dart')))

    def test_isolated_home_markers_and_cleanup(self):
        for mode in ('tooling', 'launch', 'all'):
            self.assert_success(self.run_workflow(mode))
            for call in self.calls():
                env = call['env']
                home = Path(env['HOME'])
                self.assertNotEqual(home, self.home)
                self.assertEqual(env['USERPROFILE'], str(home))
                self.assertEqual(env['PI_CODING_AGENT_DIR'], str(home / 'agent'))
                self.assertEqual(env['REMOTE_PI_HOME'], str(home / 'remote'))
                self.assertEqual(env['XDG_CONFIG_HOME'], str(home / '.config'))
                self.assertFalse(home.exists(), 'temporary HOME was not removed')
                self.assertFalse(any(value == 'must-not-inherit' for value in env.values()))

    def test_failures_propagate_and_stop_later_steps(self):
        cases = [('python3', 'scripts/test-dev-workflow.py'), ('cargo', 'fmt'),
                 ('cargo', 'clippy'), ('cargo', 'test'), ('pnpm-native', 'typecheck'),
                 ('pnpm-native', 'build'), ('pnpm-native', 'vitest'),
                 ('python3', 'scripts/test-launcher-pin-tty.py'),
                 ('bash', 'test/native/speech_to_text/run.sh'), ('flutter', 'analyze'), ('flutter', 'test')]
        for runner, arg in cases:
            with self.subTest(runner=runner, arg=arg):
                result = self.run_workflow('all', FAIL_RUNNER=runner, FAIL_ARG=arg)
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertNotIn('PASS:', result.stdout)
                self.assertEqual(self.calls()[-1]['runner'], runner)
                self.assertIn(arg, self.calls()[-1]['args'])
                self.assertFalse(Path(self.calls()[-1]['env']['HOME']).exists())

    def test_missing_or_invalid_pnpm_fails_before_checks(self):
        for pnpm in ('', 'pnpm', str(self.work / 'missing'), str(self.home)):
            with self.subTest(pnpm=pnpm):
                result = self.run_workflow('all', PNPM_NATIVE=pnpm)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('PNPM_NATIVE', result.stderr)
                self.assertEqual(self.calls(), [])

    def test_synthetic_bwrap_prerequisite_is_host_independent(self):
        self.assert_success(self.run_workflow('launch'))
        self.bwrap.unlink()
        result = self.run_workflow('launch')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('/bin/bwrap', result.stderr)
        self.assertEqual(self.calls(), [])

    def test_missing_flutter_fails_before_checks(self):
        (self.bin / 'flutter').unlink()
        result = self.run_workflow('launch')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing prerequisite: flutter', result.stderr)
        self.assertEqual(self.calls(), [])

    def test_old_node_fails_preflight(self):
        result = self.run_workflow('launch', FAIL_RUNNER='node')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Node 22.19+', result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_missing_project_prerequisites_fail_without_preparation(self):
        for name, diagnostic in (
            ('pi-extension/node_modules', 'extension dependencies'),
            ('pi-extension/build/managed-runtime/manifest.json', 'managed runtime'),
            ('app/.dart_tool/package_config.json', 'Flutter dependencies'),
            ('app/android/gradlew', 'Gradle wrapper')):
            with self.subTest(name=name):
                path = self.root / name
                backup = path.with_name(path.name + '.backup')
                path.rename(backup)
                try:
                    result = self.run_workflow('all')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(diagnostic, result.stderr)
                    self.assertEqual(self.calls(), [])
                finally:
                    backup.rename(path)

    def test_missing_gradle_distribution_fails_without_downloading(self):
        try:
            shutil.rmtree(self.home / '.gradle/wrapper/dists/gradle-8.14-all')
        except OSError as error:
            self.fail(f'Could not remove synthetic Gradle fixture: {error}')
        result = self.run_workflow('all')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cached Gradle 8.14', result.stderr)
        self.assertEqual(self.calls(), [])

    def test_make_default_is_help_and_targets_delegate(self):
        result = subprocess.run(['/usr/bin/make', '-C', str(self.root)], env=self.env,
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('make validate', result.stdout)
        self.assertEqual(self.calls(), [])
        for target, mode in (('test-tooling', 'tooling'), ('test-launch', 'launch'), ('validate', 'all')):
            result = subprocess.run(['/usr/bin/make', '-n', '-C', str(self.root), target],
                                    text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'bash scripts/validate.sh {mode}', result.stdout)


@unittest.skipUnless(NODE, 'Node not installed: read-only doctor tests skipped')
class DoctorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='doctor-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/doctor-managed-runtime.mjs', self.root / 'scripts/doctor-managed-runtime.mjs')
        self.validator = self.root / 'pi-extension/dist/session/launch_runtime.js'
        self.validator.parent.mkdir(parents=True)
        (self.validator.parent.parent / 'package.json').write_text('{"type":"module"}')
        self.validator.write_text("export async function managedRuntime(root) { return {root: root + '/build/managed-runtime'}; }")
        self.target = self.root / 'installed package'
        self.target.mkdir()
        self.env = {**os.environ, 'EXTENSION_ROOT': str(self.target)}
        self.env.pop('NODE_OPTIONS', None)

    def run_doctor(self, *args, **env):
        assert NODE is not None  # Class is skipped when Node is unavailable.
        return subprocess.run([NODE, str(self.root / 'scripts/doctor-managed-runtime.mjs'), *args],
                              env={**self.env, **env}, cwd=self.target,
                              text=True, capture_output=True, check=False)

    def test_exact_target_and_no_live_host_claim(self):
        for args in ((), (str(self.target),)):
            result = self.run_doctor(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'Canonical extension root: {self.target}', result.stdout)
            self.assertIn('active phone host path has NOT been discovered or proven', result.stdout)
            self.assertIn(str(self.validator), result.stdout)
            self.assertEqual(list(self.target.iterdir()), [])

    def test_invalid_and_missing_selection(self):
        for args in ((), ('relative',), ('--help',), (str(self.target), 'extra')):
            result = self.run_doctor(*args, EXTENSION_ROOT='')
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertNotIn('PASS:', result.stdout)

    def test_missing_built_validator_fails_without_building(self):
        self.validator.unlink()
        result = self.run_doctor()
        self.assertEqual(result.returncode, 1)
        self.assertIn('Missing built checkout validator', result.stderr)
        self.assertFalse(self.validator.exists())

    def test_validation_failure_propagates_without_repair(self):
        self.validator.write_text("export async function managedRuntime() { throw new Error('synthetic invalid runtime'); }")
        result = self.run_doctor()
        self.assertEqual(result.returncode, 1)
        self.assertIn('synthetic invalid runtime', result.stderr)
        self.assertNotIn('PASS:', result.stdout)
        self.assertEqual(list(self.target.iterdir()), [])

    def test_missing_target_is_not_replaced_by_checkout_or_global_package(self):
        result = self.run_doctor(str(self.root / 'missing'))
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('PASS:', result.stdout)
        self.assertFalse((self.root / 'missing').exists())


if __name__ == '__main__':
    unittest.main()
