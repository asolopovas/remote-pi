"""Offline publisher guards: python3 scripts/test-docker-publishers.py."""
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECTS = ('relay', 'site', 'rp-s3')


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.bin = self.work / 'bin'
        self.bin.mkdir()
        self.log = self.work / 'calls'
        self.env = {**os.environ, 'HOME': str(self.work),
                    'PATH': f'{self.bin}:/usr/bin:/bin', 'CALLS': str(self.log)}
        self.env.pop('DOCKER_IMAGE', None)
        # No real Docker, build, login or network operation can run in these tests.
        docker = self.bin / 'docker'
        docker.write_text('''#!/usr/bin/python3
import json, os, sys
with open(os.environ['CALLS'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['buildx', 'inspect']:
    sys.exit(int(os.environ.get('INSPECT_STATUS', '0')))
if sys.argv[1:3] == ['buildx', 'build']:
    sys.exit(int(os.environ.get('BUILD_STATUS', '0')))
''')
        docker.chmod(0o755)
        for command in ('curl', 'wget', 'ssh'):
            mock = self.bin / command
            mock.write_text('#!/bin/bash\necho unexpected-network >> "$CALLS"\nexit 97\n')
            mock.chmod(0o755)

    def run_publisher(self, project, image=None, args=(), **env):
        self.log.unlink(missing_ok=True)
        if image is not None:
            env['DOCKER_IMAGE'] = image
        return subprocess.run(
            ['/bin/bash', str(ROOT / project / 'push-docker.sh'), *args],
            cwd=self.work, env={**self.env, **env}, text=True,
            capture_output=True, check=False)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_unset_empty_and_invalid_destinations_execute_nothing(self):
        for project in PROJECTS:
            for image in (None, '', 'repo', '/repo', 'owner/', 'Owner/repo',
                          'owner/Repo', 'https://registry.example/owner/repo',
                          'owner/repo:latest', 'owner/repo@sha256:abc',
                          '-flag/repo', 'owner/../repo', 'owner//repo',
                          'owner/repo --push', ' owner/repo', 'owner/repo\n',
                          'owner/$(touch nope)', 'owner/repo;true',
                          'registry.example:0/repo', 'registry.example:65536/repo',
                          'registry.example:123456/repo', 'bad..host/repo',
                          'owner/' + 'a' * 250):
                with self.subTest(project=project, image=image):
                    result = self.run_publisher(project, image)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('error:', result.stderr)
                    self.assertIn('DOCKER_IMAGE', result.stderr)
                    self.assertEqual(self.calls(), [])

    def test_explicit_destinations_preserve_builds_and_tags(self):
        for project in PROJECTS:
            for image in ('independent/publisher', 'registry.example/team/publisher',
                          'localhost:5000/team/publisher',
                          'registry.example:65535/publisher',
                          'independent/repo__name--part.v2'):
                for create in (False, True):
                    for version in (('', 'v1.2.3') if project == 'site' else ('',)):
                        with self.subTest(project=project, image=image, create=create, version=version):
                            result = self.run_publisher(project, image,
                                                        args=(version,) if version else (),
                                                        INSPECT_STATUS='1' if create else '0')
                            self.assertEqual(result.returncode, 0, result.stderr)
                            expected = [['buildx', 'inspect', 'multiarch']]
                            if create:
                                expected.append(['buildx', 'create', '--name', 'multiarch',
                                                 '--driver', 'docker-container', '--bootstrap'])
                            expected.append(['buildx', 'use', 'multiarch'])
                            if project != 'site':
                                manifest = (ROOT / project / 'Cargo.toml').read_text()
                                match = re.search(r'^version\s*=\s*"([^"]+)"', manifest, re.M)
                                if match is None:
                                    self.fail('Cargo.toml is missing its version')
                                version = 'v' + match[1]
                            tags = ['--tag', f'{image}:{version}'] if version else []
                            expected.append(['buildx', 'build', '--platform',
                                             'linux/amd64,linux/arm64', *tags,
                                             '--tag', f'{image}:latest', '--push', '.'])
                            self.assertEqual(self.calls(), expected)

    def test_build_failure_is_not_reported_as_success(self):
        for project in PROJECTS:
            with self.subTest(project=project):
                result = self.run_publisher(project, 'independent/publisher', BUILD_STATUS='19')
                self.assertEqual(result.returncode, 19)
                self.assertNotIn('✓', result.stdout)
                self.assertEqual(self.calls()[-1][:2], ['buildx', 'build'])


if __name__ == '__main__':
    unittest.main()
