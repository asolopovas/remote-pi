#!/usr/bin/env python3
"""Local Android client update only. Invoke under the machine lease; no provisioning."""
import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'io.github.asolopovas.remotepi.readable'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(*args, cwd=ROOT, env=None, timeout=3600):
    print('==>', Path(cwd).name, *map(str, args), flush=True)
    return subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True,
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          timeout=timeout).stdout


def executable(value, label):
    try:
        valid = bool(value and Path(value).is_absolute() and Path(value).is_file()
                     and os.access(value, os.X_OK))
    except (OSError, ValueError) as error:
        raise RuntimeError(f'invalid {label}: {error}') from error
    require(valid, f'set {label} to an existing absolute executable')
    return value


def match(pattern, text, label):
    found = re.search(pattern, text, re.MULTILINE)
    require(found is not None, f'cannot establish {label}')
    return found.group(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-only', action='store_true', help='all gates/build/verification, no install or launch')
    args = parser.parse_args()
    gitleaks = executable(os.environ.get('GITLEAKS', shutil.which('gitleaks')), 'GITLEAKS')
    pnpm = executable(os.environ.get('PNPM_NATIVE'), 'PNPM_NATIVE')
    for tool in ('flutter', 'adb', 'cargo', 'java', 'make', 'git'):
        require(shutil.which(tool), f'missing prerequisite: {tool}')
    sdk = Path(os.environ.get('ANDROID_HOME', os.environ.get('ANDROID_SDK_ROOT', str(Path.home() / 'Android/Sdk'))))
    tools = sorted((sdk / 'build-tools').glob('*/apksigner'), key=lambda p: tuple(int(n) for n in p.parent.name.split('.')))
    require(bool(tools), 'missing Android SDK build tools')
    apksigner = executable(str(tools[-1]), 'SDK apksigner')
    aapt = executable(str(tools[-1].with_name('aapt')), 'SDK aapt')
    require(re.search(r'\b17[.\"]', run('java', '-version')), 'JDK 17 required (set JAVA_HOME and PATH)')
    try:
        flutter_version = json.loads(run('flutter', '--version', '--machine'))['frameworkVersion']
    except (ValueError, KeyError) as error:
        raise RuntimeError('cannot establish Flutter version') from error
    require(flutter_version == '3.44.4', 'Flutter 3.44.4 required')
    cache = Path(os.environ.get('GRADLE_USER_HOME', str(Path.home() / '.gradle'))).resolve()
    require(bool(list(cache.glob('wrapper/dists/gradle-8.14-all/*/gradle-8.14/bin/gradle'))), 'missing cached Gradle 8.14 all distribution')
    require((cache / 'caches').is_dir(), 'missing Gradle dependency cache')
    require((ROOT / 'app/.dart_tool/package_config.json').is_file(), 'missing resolved Pub dependencies')

    if not (ROOT / 'app/android/key.properties').exists():
        require((Path.home() / '.android/debug.keystore').is_file(),
                'missing existing debug signing key; provision signing explicitly, never regenerate for an update')

    serial = os.environ.get('ADB_SERIAL', '')

    def device():
        rows = [line.split()[:2] for line in run('adb', 'devices', timeout=30).splitlines()[1:] if line.strip()]
        if serial:
            require([serial, 'device'] in rows, 'selected ADB_SERIAL missing, offline or unauthorized')
            return serial
        require(len(rows) == 1 and rows[0][1] == 'device', 'select an authorized online device with ADB_SERIAL (ambiguous/missing device)')
        return rows[0][0]

    selected = device()

    def adb(*parts):
        require(device() == selected, 'device selection changed')
        return run('adb', '-s', selected, *parts, timeout=180)

    def installed():
        dump = adb('shell', 'dumpsys', 'package', PACKAGE)
        return int(match(r'\bversionCode=(\d+)', dump, 'installed versionCode'))

    old = installed()  # Updates only: never silently create a different installation.
    require('arm64-v8a' in adb('shell', 'getprop', 'ro.product.cpu.abilist').strip().split(','), 'device must support ARM64')
    pub = (ROOT / 'app/pubspec.yaml').read_text()
    name = match(r'^version: ([\d.]+)\+\d+\s*$', pub, 'pubspec versionName')
    source_code = match(r'^version: [\d.]+\+(\d+)\s*$', pub, 'pubspec versionCode')
    number = max(old + 1, int(source_code) + 1)
    require(number <= 2100000000, 'Android versionCode exhausted')

    # No publication/deployment gate is replaced by a prior run or a build-only run.
    print(run(gitleaks, 'git', '.', '--log-opts=HEAD', '--redact=100'))
    print(run('python3', 'scripts/check-docs.py'))
    for directory in ('site', 'pi-extension'):
        print(run(pnpm, 'audit', cwd=ROOT / directory))
    for directory in ('relay', 'rp-s3', 'cockpit/cli'):
        print(run('cargo', 'audit', cwd=ROOT / directory))
    print(run('make', 'validate', timeout=7200))

    with tempfile.TemporaryDirectory(prefix='remote-pi-android-') as temporary:
        work = Path(temporary)
        gradle = work / 'gradle'
        (gradle / 'init.d').mkdir(parents=True)
        (gradle / 'wrapper').mkdir()
        (gradle / 'caches').symlink_to(cache / 'caches', target_is_directory=True)
        (gradle / 'wrapper/dists').symlink_to(cache / 'wrapper/dists', target_is_directory=True)
        (gradle / 'init.d/offline.gradle').write_text(
            'gradle.startParameter.offline = true\n'
            'gradle.beforeProject { p -> p.ext.set("android.builder.sdkDownload", "false"); '
            'p.plugins.withId("com.android.application") { '
            'p.androidComponents.finalizeDsl { android -> '
            'android.defaultConfig.ndk.abiFilters.clear(); '
            'android.defaultConfig.ndk.abiFilters.add("arm64-v8a") } } }\n')
        env = {**os.environ, 'GRADLE_USER_HOME': str(gradle), 'CI': 'true',
               'GRADLE_OPTS': '-Dorg.gradle.daemon=false -Dandroid.builder.sdkDownload=false',
               'FLUTTER_SUPPRESS_ANALYTICS': 'true', 'DART_SUPPRESS_ANALYTICS': 'true'}
        apk = ROOT / 'app/build/app/outputs/flutter-apk/app-release.apk'
        apk.unlink(missing_ok=True)  # A successful command without new output cannot reuse an old APK.
        print(run('flutter', 'build', 'apk', '--release', '--target-platform', 'android-arm64',
                  '--no-pub', '--build-number', number, cwd=ROOT / 'app', env=env))
        require(apk.is_file(), 'fresh build produced no APK')
        badging = run(aapt, 'dump', 'badging', apk)
        require(match(r"^package: name='([^']+)'", badging, 'APK package') == PACKAGE, 'APK package mismatch')
        require(int(match(r"versionCode='(\d+)'", badging, 'APK versionCode')) == number, 'APK versionCode mismatch')
        require(match(r"versionName='([^']+)'", badging, 'APK versionName') == name, 'APK versionName mismatch')
        require(match(r"^native-code: (.+)$", badging, 'APK ABI').strip() == "'arm64-v8a'", 'APK must contain only ARM64 native code')

        def certificates(path):
            output = run(apksigner, 'verify', '--print-certs', path)
            certs = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)$', output, re.MULTILINE)
            require(bool(certs), 'cannot establish APK signing certificate')
            return sorted(c.lower() for c in certs)

        built_certs = certificates(apk)
        paths = adb('shell', 'pm', 'path', PACKAGE).splitlines()
        base = [p.removeprefix('package:') for p in paths if p.endswith('/base.apk')]
        require(len(base) == 1 and base[0].startswith('/'), 'cannot establish installed base APK')
        installed_apk = work / 'installed.apk'
        adb('pull', base[0], installed_apk)
        installed_badging = run(aapt, 'dump', 'badging', installed_apk)
        require(match(r"^package: name='([^']+)'", installed_badging, 'installed APK package') == PACKAGE, 'installed APK package mismatch')
        require(int(match(r"versionCode='(\d+)'", installed_badging, 'installed APK versionCode')) == old, 'installed APK versionCode mismatch')
        require(certificates(installed_apk) == built_certs, 'installed signing certificate mismatch; refusing incompatible update')
        require(installed() == old and number > old, 'installed version changed or downgrade attempted')
        print(f'Verified {PACKAGE} {name} versionCode={number} ARM64; installed={old}; signatures match. APK: {apk}')
        if args.build_only:
            print('BUILD ONLY: no install or launch performed.')
            return
        result = adb('install', '-r', apk)
        require('Success' in result, 'ADB did not confirm install success')
        require(installed() == number, 'installed versionCode does not match built APK')
        component = adb('shell', 'cmd', 'package', 'resolve-activity', '--brief', PACKAGE).strip().splitlines()[-1]
        require(component.startswith(PACKAGE + '/') and re.fullmatch(r'[\w.$/]+', component), 'cannot resolve app launch activity')
        launch = adb('shell', 'am', 'start', '-W', '-n', component)
        require(re.search(r'^Status: ok\s*$', launch, re.MULTILINE), 'install succeeded but app launch not confirmed')
        print(f'PASS: installed versionCode={number}; launch confirmed. No host/relay deployment performed.')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stdout or '', flush=True)
        raise SystemExit(f'FAILED: command exited {error.returncode}; no subsequent steps performed') from None
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f'FAILED: {error}') from None
