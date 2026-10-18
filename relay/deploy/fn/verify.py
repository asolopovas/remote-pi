#!/usr/bin/env python3
"""fn acceptance probe: ephemeral keys; only its Owner row is removed in finally.

Requires cryptography and websockets. Explicit --ssh-host authorizes restarting
this dedicated relay and an isolated restore container, never unrelated services.
No private identities, signatures, or message bodies are printed or saved.
"""
import argparse
import asyncio
import base64
import hashlib
import json
import ssl
import subprocess
import time
import uuid
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, HTTPSHandler, ProxyHandler, build_opener

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from websockets.exceptions import ConnectionClosed
from websockets.legacy.client import connect as websocket_connect

IP = "173.208.50.216"
TLS = ssl.create_default_context()
TLS.minimum_version = TLS.maximum_version = ssl.TLSVersion.TLSv1_3


def b64(value):
    return base64.b64encode(value).decode("ascii")


def public(key):
    return key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


# Match direct connections: ignore environment proxies and never follow redirects.
HTTP = build_opener(ProxyHandler({}), HTTPSHandler(context=TLS), NoRedirect())
HTTP.addheaders = [("Content-Type", "application/json")]


def http(path, data=None):
    if not path.startswith("/") or path.startswith("//"):
        raise ValueError("Expected a relay-local absolute path")
    body = None if data is None else json.dumps(data).encode()
    try:
        with HTTP.open(f"https://{IP}{path}", data=body, timeout=15) as response:
            return response.status, response.read()
    except HTTPError as error:
        with error:
            return error.code, error.read()


def ssh(host, script, *arguments):
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", host, "sudo", "python3", "-", *arguments],
        input=script, text=True, capture_output=True, timeout=120, check=True,
    )
    print(result.stdout.strip())


def decode_json_object(data, context):
    try:
        value = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError):
        raise RuntimeError(f"Invalid JSON in {context}") from None
    if not isinstance(value, dict):
        raise RuntimeError(f"Expected a JSON object in {context}")
    return value


async def receive(ws):
    return decode_json_object(await asyncio.wait_for(ws.recv(), 10), "relay WebSocket frame")


async def connect(key, invalid=False):
    ws = await websocket_connect(f"wss://{IP}", ssl=TLS, open_timeout=15)
    assert ws.transport.get_extra_info("ssl_object").version() == "TLSv1.3"
    await ws.send(json.dumps({"type": "hello", "pubkey": b64(public(key))}))
    challenge = await receive(ws)
    assert challenge["type"] == "challenge"
    nonce = base64.b64decode(challenge["nonce"], validate=True)
    assert len(nonce) == 32
    signature = bytes(64) if invalid else key.sign(nonce)
    await ws.send(json.dumps({"type": "auth", "sig": b64(signature)}))
    if invalid:
        try:
            await asyncio.wait_for(ws.recv(), 10)
            raise AssertionError("invalid auth was not rejected")
        except ConnectionClosed:
            await ws.close()
            return None
    # There is no auth_ok in this protocol; authenticated control reply proves it.
    await ws.send(json.dumps({"type": "presence_check", "peers": []}))
    assert (await receive(ws))["type"] == "presence"
    return ws


async def route(a, b, key_a, key_b):
    # App/Pi outer payload remains opaque, tested independently of mesh routes.
    outer = {"peer": b64(public(key_b)), "ct": b64(b"synthetic probe")}
    await a.send(json.dumps(outer))
    received = await receive(b)
    assert received["ct"] == outer["ct"]
    assert received["peer"] == b64(public(key_a))
    envelope = {
        "from": "/synthetic@probe", "to": "/synthetic@receiver",
        "id": str(uuid.uuid4()), "re": None, "body": {"synthetic": True},
    }
    await a.send(json.dumps({
        "type": "pi_envelope", "to_pc": b64(public(key_b)), "envelope": envelope,
    }))
    received = await receive(b)
    assert received["type"] == "pi_envelope_in"
    assert received["from_pc"] == b64(public(key_a))
    assert received["envelope"] == envelope
    await a.send(json.dumps({
        "type": "pi_envelope", "to_pc": b64(public(Ed25519PrivateKey.generate())),
        "envelope": envelope,
    }))
    denied = await receive(a)
    assert denied["from_pc"] == "_relay"
    assert denied["envelope"]["body"]["reason"] == "not_authorized"
    assert denied["envelope"]["re"] == envelope["id"]
    print("PASS: authenticated outer routing, authorized Pi routing, unauthorized route rejection")


def restore_script(owner_hash):
    # Restore from an online backup into a new volume; no network or published ports.
    return f'''
import json, os, pathlib, shutil, sqlite3, subprocess, time
os.chdir('/opt/remote-pi-relay')
def docker(*args):
    return subprocess.check_output(['docker', *args], text=True).strip()
report = subprocess.check_output(['./backup.sh'], text=True)
print(report, end='')
backup = pathlib.Path('backups') / report.strip().rsplit(': ', 1)[1]
assert backup.parent == pathlib.Path('backups') and backup.suffix == '.db'
name = 'remote-pi-relay-restore-check'
volume = name + '-data'
assert volume not in docker('volume', 'ls', '-q').splitlines()
assert name not in docker('ps', '-a', '--format', '{{{{.Names}}}}').splitlines()
docker('volume', 'create', volume)
try:
    mount = pathlib.Path(docker('volume', 'inspect', '-f', '{{{{.Mountpoint}}}}', volume))
    shutil.copyfile(backup, mount / 'mesh.db')
    env = dict(line.split('=', 1) for line in pathlib.Path('.env').read_text().splitlines())
    uid, gid = int(env['CONTAINER_UID_OFFSET']) + 10001, int(env['CONTAINER_GID_OFFSET']) + 10001
    os.chown(mount, uid, gid)
    os.chmod(mount, 0o700)
    os.chown(mount / 'mesh.db', uid, gid)
    os.chmod(mount / 'mesh.db', 0o600)
    docker('run', '-d', '--name', name, '--network', 'none', '--read-only',
           '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
           '--user', '10001:10001', '--memory', '512m', '--cpus', '1', '--pids-limit', '128',
           '-e', 'RUST_LOG=error', '-v', volume + ':/data', env['RELAY_IMAGE'])
    for _ in range(30):
        r = subprocess.run(['docker', 'exec', name, 'curl', '-fsS', 'http://127.0.0.1:3000/health'], capture_output=True)
        if r.returncode == 0:
            break
        time.sleep(1)
    assert r.returncode == 0
    response = json.loads(docker('exec', name, 'curl', '-fsS', 'http://127.0.0.1:3000/mesh/{owner_hash}'))
    assert response['version'] == 1
    with sqlite3.connect(mount / 'mesh.db') as db:
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    print('PASS: online backup and isolated non-root relay restore, signed mesh row preserved')
finally:
    subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    docker('volume', 'rm', volume)
    backup.unlink()  # Remove this probe's synthetic snapshot, not operator backups.
'''


async def main(host):
    owner, key_a, key_b = [Ed25519PrivateKey.generate() for _ in range(3)]
    owner_hash = hashlib.sha256(public(owner)).hexdigest()
    path = f"/mesh/{owner_hash}"
    sockets = []
    created = False
    try:
        assert http("/health") == (200, b"OK")
        assert http(path)[0] == 404
        await connect(key_a, invalid=True)
        print("PASS: trusted HTTPS/IP SAN/TLS1.3, WSS upgrade and invalid auth rejection")
        blob = json.dumps({
            "version": 1, "issued_at": int(time.time() * 1000),
            "owner_pk": b64(public(owner)),
            "members": [{"remote_epk": b64(public(key)), "relay_url": f"wss://{IP}",
                         "paired_at": "2026-10-14T00:00:00Z"} for key in (key_a, key_b)],
        }, separators=(",", ":"), sort_keys=True).encode()
        wire = {"blob": b64(blob), "sig": b64(owner.sign(blob))}
        assert http(path, {**wire, "sig": b64(bytes(64))})[0] == 403
        assert http(path, wire)[0] == 200
        created = True
        assert http(path, wire)[0] == 409
        status, response = http(path)
        assert status == 200
        assert decode_json_object(response, "mesh HTTP response")["blob"] == wire["blob"]
        assert http(path + "?since=1")[0] == 304
        print("PASS: mesh signature rejection, POST/GET compatibility, monotonic version and since semantics")
        a, b = await connect(key_a), await connect(key_b)
        assert a is not None and b is not None
        sockets.extend([a, b])
        await route(a, b, key_a, key_b)
        await asyncio.sleep(28)  # Survive a relay heartbeat interval behind nginx.
        await a.send(json.dumps({"type": "rooms_check", "peers": [b64(public(key_b))]}))
        assert (await receive(a))["type"] == "rooms"
        print("PASS: WSS remains usable beyond the 25-second relay heartbeat")
        ssh(host, "import os,subprocess\nos.chdir('/opt/remote-pi-relay')\nsubprocess.run(['docker','compose','restart','relay','proxy'],check=True,stdout=subprocess.DEVNULL)\nprint('Dedicated relay and proxy restarted')\n")
        for ws in sockets:
            await ws.close()
        sockets.clear()
        for _ in range(30):
            if http("/health")[0] == 200:
                break
            await asyncio.sleep(1)
        assert decode_json_object(http(path)[1], "mesh HTTP response")["blob"] == wire["blob"]
        a, b = await connect(key_a), await connect(key_b)
        assert a is not None and b is not None
        sockets.extend([a, b])
        await route(a, b, key_a, key_b)
        print("PASS: volume persistence and authenticated reconnect/routing after relay restart")
        ssh(host, restore_script(owner_hash))
    finally:
        for ws in sockets:
            await ws.close()
        if created:
            # Delete only the row whose hash was generated by this invocation.
            ssh(host, '''
import sqlite3, subprocess, sys
owner_hash = sys.argv[1]
assert len(owner_hash) == 64 and all(c in '0123456789abcdef' for c in owner_hash)
mount = subprocess.check_output(['docker','volume','inspect','-f','{{.Mountpoint}}','remote-pi-relay-data'],text=True).strip()
with sqlite3.connect(mount + '/mesh.db') as db:
    db.execute('DELETE FROM mesh_versions WHERE owner_pk_hash = ?', (owner_hash,))
    assert db.execute('SELECT count(*) FROM mesh_versions WHERE owner_pk_hash = ?', (owner_hash,)).fetchone()[0] == 0
print('PASS: only synthetic Owner row cleaned up')
''', owner_hash)
            assert http(path)[0] == 404


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ssh-host", required=True)
    asyncio.run(main(parser.parse_args().ssh_host))
