"""Linux PTY regression for the built CLI: synthetic PIN, isolated temporary HOME."""
import json
import os
import pathlib
import pty
import select
import subprocess
import tempfile
import time

CLI = str(pathlib.Path(__file__).resolve().parent.parent / 'dist/bin/launcher.js')
with tempfile.TemporaryDirectory(prefix='secure-launch-pin-tty-') as home:
    master, slave = pty.openpty()
    env = dict(os.environ, HOME=home)
    process = subprocess.Popen(['node', CLI, 'pin-setup'], stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True)
    os.close(slave)
    output = bytearray()
    def wait_for(marker):
        deadline = time.monotonic() + 10
        while marker not in output:
            if time.monotonic() >= deadline:
                raise RuntimeError('TTY setup prompt deadline exceeded')
            if select.select([master], [], [], 0.2)[0]:
                output.extend(os.read(master, 4096))
    try:
        wait_for(b'input hidden): ')
        os.write(master, b'654321\r')
        wait_for(b'Confirm PIN: ')
        os.write(master, b'654321\r')
        wait_for(b'PIN verifier saved.')
        assert process.wait(timeout=10) == 0
        assert b'654321' not in output, 'Synthetic PIN was echoed'
        path = pathlib.Path(home) / '.pi/remote/launcher/pin.json'
        record = json.loads(path.read_text())
        assert record['version'] == 1 and len(record['salt']) == 64 and len(record['verifier']) == 64
        assert '654321' not in path.read_text()
        assert path.stat().st_mode & 0o777 == 0o600
        assert path.parent.stat().st_mode & 0o777 == 0o700
        print('PASS: actual interactive CLI accepts hidden synthetic PIN confirmation in isolated HOME; no echo/plaintext storage, verifier0600 and directory0700. Temporary setup removed; operator PIN untouched.')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
