#!/usr/bin/env python3
"""Offline subprocess contract: no SDK, phone, network or machine lease needed."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
n = Path(sys.argv[0]).name
a = sys.argv[1:]
r = Path(os.environ['REPO'])
with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps([n, a, os.getcwd()])+'\n')
if os.environ.get('FAIL') == n or os.environ.get('FAIL') == n+':'+(' '.join(a)): sys.exit(23)
if n == 'java': print('openjdk version "17.0.1"')
if n == 'flutter':
    if '--machine' in a: print('{"frameworkVersion":"3.44.4"}')
    else:
        assert '--no-pub' in a and '--release' in a and 'android-arm64' in a
        init = (Path(os.environ['GRADLE_USER_HOME'])/'init.d/offline.gradle').read_text()
        assert 'offline = true' in init
        assert 'finalizeDsl' in init and 'abiFilters.add("arm64-v8a")' in init
        p = r/'app/build/app/outputs/flutter-apk/app-release.apk'
        assert not p.exists(), 'stale APK not removed'
        p.parent.mkdir(parents=True, exist_ok=True)
        if not os.environ.get('NO_APK'): p.write_text('fresh')
if n == 'aapt':
    installed = a[-1].endswith('installed.apk')
    package = os.environ.get('INSTALLED_PACKAGE' if installed else 'APK_PACKAGE', 'io.github.asolopovas.remotepi.readable')
    code = os.environ.get('INSTALLED_CODE','57') if installed else os.environ.get('APK_CODE','58')
    print("package: name='%s' versionCode='%s' versionName='1.2.0'" % (package,code))
    print("native-code: 'arm64-v8a'")
if n == 'apksigner':
    print('Signer #1 certificate SHA-256 digest: '+('bb' if os.environ.get('CERT_MISMATCH') and a[-1].endswith('installed.apk') else 'aa'))
if n == 'adb':
    if a == ['devices']:
        print('List of devices attached\n'+os.environ.get('DEVICES','phone\tdevice'))
    else:
        assert a[:2] == ['-s','phone']
        a = a[2:]
        if a[:3] == ['shell','dumpsys','package']:
            print('versionCode='+ (os.environ.get('POST_CODE','58') if (r/'installed').exists() else '57'))
        if 'getprop' in a: print('arm64-v8a,armeabi-v7a')
        if a[:3] == ['shell','pm','path']: print('package:/data/app/sample/base.apk')
        if a[0] == 'pull': Path(a[-1]).write_text('installed')
        if a[0] == 'install':
            assert a[1] == '-r' and len(a) == 3
            (r/'installed').touch(); print('Success')
        if 'resolve-activity' in a: print('io.github.asolopovas.remotepi.readable/work.jacobmoura.remotepi.MainActivity')
        if 'start' in a: print('Status: '+os.environ.get('LAUNCH_STATUS','ok'))
'''


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='deploy-contract-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for directory in ('scripts', 'app/.dart_tool', '.android', 'site', 'pi-extension', 'relay', 'rp-s3', 'cockpit/cli', 'bin', 'sdk/build-tools/35.0.0', 'gradle/caches', 'gradle/wrapper/dists/gradle-8.14-all/cached/gradle-8.14/bin'):
            (self.root/directory).mkdir(parents=True)
        shutil.copy2(ROOT/'scripts/deploy-android.py', self.root/'scripts/deploy-android.py')
        (self.root/'.android/debug.keystore').touch()
        (self.root/'app/.dart_tool/package_config.json').touch()
        (self.root/'gradle/wrapper/dists/gradle-8.14-all/cached/gradle-8.14/bin/gradle').touch()
        (self.root/'app/pubspec.yaml').write_text('version: 1.2.0+8\n')
        for name in ('flutter', 'adb', 'cargo', 'java', 'make', 'git', 'gitleaks', 'pnpm-native', 'python3'):
            path = self.root/'bin'/name
            path.write_text(FAKE)
            path.chmod(0o755)
        for name in ('aapt', 'apksigner'):
            path = self.root/'sdk/build-tools/35.0.0'/name
            path.write_text(FAKE)
            path.chmod(0o755)
        self.log = self.root/'calls'
        self.env = {**os.environ, 'PATH': str(self.root/'bin')+':/usr/bin:/bin',
                    'REPO': str(self.root), 'CALLS': str(self.log), 'HOME': str(self.root),
                    'GITLEAKS': str(self.root/'bin/gitleaks'), 'PNPM_NATIVE': str(self.root/'bin/pnpm-native'),
                    'ANDROID_HOME': str(self.root/'sdk'), 'GRADLE_USER_HOME': str(self.root/'gradle'), 'ADB_SERIAL': 'phone'}

    def execute(self, *args, **env):
        return subprocess.run(['/usr/bin/python3', str(self.root/'scripts/deploy-android.py'), *args], env={**self.env, **env}, capture_output=True, text=True)

    def calls(self):
        try:
            return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        except (OSError, ValueError) as error:
            self.fail(f'Invalid fake-runner log: {error}')

    def installs(self):
        return [a for n,a,_ in self.calls() if n == 'adb' and 'install' in a]

    def test_success_gates_order_scope_and_update_only(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('launch confirmed', result.stdout)
        calls = self.calls()
        gates = [(n,a,Path(c).relative_to(self.root).as_posix()) for n,a,c in calls if n in ('gitleaks','python3','pnpm-native','cargo','make')]
        self.assertEqual(gates, [('gitleaks',['git','.','--log-opts=HEAD','--redact=100'],'.'), ('python3',['scripts/check-docs.py'],'.'), ('pnpm-native',['audit'],'site'), ('pnpm-native',['audit'],'pi-extension'), ('cargo',['audit'],'relay'), ('cargo',['audit'],'rp-s3'), ('cargo',['audit'],'cockpit/cli'), ('make',['validate'],'.')])
        self.assertEqual(len(self.installs()), 1)
        self.assertEqual(self.installs()[0][2:4], ['install','-r'])
        build = next(a for n,a,_ in calls if n == 'flutter' and 'build' in a)
        self.assertEqual(build[-2:], ['--build-number','58'])

    def test_every_failed_gate_and_build_prevents_install(self):
        for failure in ('gitleaks','python3','pnpm-native','cargo','make','flutter:build apk --release --target-platform android-arm64 --no-pub --build-number 58'):
            with self.subTest(failure=failure):
                result = self.execute(FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.installs(), [])

    def test_invalid_device_prevents_gates_and_install(self):
        for rows,serial in [('phone\tunauthorized','phone'), ('phone\toffline','phone'), ('phone\tdevice\nother\tdevice',''), ('','phone')]:
            with self.subTest(rows=rows):
                self.log.unlink(missing_ok=True)
                self.assertNotEqual(self.execute(DEVICES=rows, ADB_SERIAL=serial).returncode, 0)
                self.assertFalse(any(n == 'make' for n,_,_ in self.calls()))
                self.assertEqual(self.installs(), [])

    def test_apk_comparison_fails_closed(self):
        for env in ({'APK_PACKAGE':'wrong.package'}, {'APK_CODE':'57'}, {'CERT_MISMATCH':'1'}, {'NO_APK':'1'}, {'INSTALLED_PACKAGE':'wrong.package'}, {'INSTALLED_CODE':'56'}):
            with self.subTest(env=env):
                self.assertNotEqual(self.execute(**env).returncode, 0)
                self.assertEqual(self.installs(), [])

    def test_build_only_and_stale_apk(self):
        apk = self.root/'app/build/app/outputs/flutter-apk/app-release.apk'
        apk.parent.mkdir(parents=True)
        apk.write_text('stale')
        result = self.execute('--build-only')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertEqual(apk.read_text(), 'fresh')
        self.assertEqual(self.installs(), [])

    def test_pubspec_floor_not_persisted(self):
        pub = self.root/'app/pubspec.yaml'
        pub.write_text('version: 1.2.0+90\n')
        result = self.execute('--build-only', APK_CODE='91')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertEqual(pub.read_text(), 'version: 1.2.0+90\n')

    def test_missing_signing_or_scanner_fails_before_gates(self):
        result = self.execute(GITLEAKS=str(self.root/'missing'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])
        (self.root/'.android/debug.keystore').unlink()
        result = self.execute()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(n == 'make' for n,_,_ in self.calls()))
        self.assertEqual(self.installs(), [])

    def test_post_install_version_and_launch_failure_reported(self):
        result = self.execute(POST_CODE='57')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('launch confirmed', result.stdout)
        (self.root/'installed').unlink()
        result = self.execute(LAUNCH_STATUS='error')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('launch confirmed', result.stdout)


if __name__ == '__main__':
    unittest.main()
