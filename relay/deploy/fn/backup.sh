#!/bin/sh
# SQLite online backup API, never a blind copy of a live rollback-journal DB.
set -eu
umask 077
cd /opt/remote-pi-relay
exec 9>/run/lock/remote-pi-relay-backup.lock
flock -n 9 || exit 0
mountpoint=$(docker volume inspect -f '{{.Mountpoint}}' remote-pi-relay-data)
python3 - "$mountpoint/mesh.db" "$PWD/backups" <<'PY'
import datetime
import pathlib
import sqlite3
import sys

source, directory = sys.argv[1:]
name = datetime.datetime.now(datetime.timezone.utc).strftime('mesh-%Y%m%dT%H%M%S%fZ.db')
target = pathlib.Path(directory) / name
with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as src:
    with sqlite3.connect(target) as dst:
        src.backup(dst)
        assert dst.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
print(f'Consistent SQLite backup verified: {target.name}')
PY
