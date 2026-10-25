#!/usr/bin/python3
"""Quiesce one local installation and retain complete database/config backups.

Install as /usr/local/sbin/process-intelligence-backup, owned by root. This
program requires the matching backup.service: its ExecStopPost restores the
application after a timeout or signal. PostgreSQL uses local peer authentication
as the postgres OS account. No database password is accepted on the command line.
"""

import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

BACKUPS = Path('/var/backups/process-intelligence')
RUNTIME = Path('/run/process-intelligence-backup')
MARKER = RUNTIME / 'restart-needed'
APP = 'process-intelligence.service'
DATABASE = 'process_intelligence'
KEEP = 14
CONFIG_PATHS = [
    '/etc/process-intelligence',
    '/etc/caddy',
    '/etc/systemd/system/process-intelligence.service',
    '/etc/systemd/system/process-intelligence-proxy.service',
    '/etc/systemd/system/process-intelligence-backup.service',
    '/etc/systemd/system/process-intelligence-backup.timer',
    '/usr/local/sbin/process-intelligence-backup',
    '/etc/postgresql/18/main',
    '/etc/ufw',
]


def run(args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=240, **kwargs).stdout


def postgres(args):
    return run(['runuser', '-u', 'postgres', '--', *args])


def file_sha256(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def restart_if_needed():
    if MARKER.exists():
        run(['systemctl', 'start', APP])
        health = run(['curl', '--fail', '--silent', '--show-error', '--retry', '8',
                      '--retry-connrefused', '--retry-delay', '1', '--max-time', '5',
                      'http://127.0.0.1:3000/health'])
        if json.loads(health).get('status') != 'ready':
            raise RuntimeError('Application restarted but is not ready')
        MARKER.unlink()


def backup():
    if subprocess.run(['systemctl', 'is-active', '--quiet', APP]).returncode != 0:
        return dict(status='backup_skipped', reason='application_not_running')
    database_bytes = int(postgres(['psql', '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1',
                                  '-d', DATABASE, '-c',
                                  'SELECT pg_database_size(current_database());']).strip())
    required = max(2 * 1024**3, database_bytes * 2)
    if shutil.disk_usage(BACKUPS).free < required:
        raise RuntimeError('Insufficient backup space; application left running')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    destination = BACKUPS / (stamp + '.partial')
    destination.mkdir(mode=0o700)
    MARKER.write_text(stamp)
    try:
        run(['systemctl', 'stop', APP])
        if run(['systemctl', 'show', APP, '-p', 'MainPID', '--value']).strip() != b'0':
            raise RuntimeError('Application has not stopped')
        with (destination / 'database.dump').open('wb') as stream:
            subprocess.run(['runuser', '-u', 'postgres', '--', 'pg_dump', '-Fc', '-d', DATABASE],
                           stdout=stream, stderr=subprocess.PIPE, timeout=240, check=True)
        (destination / 'cluster-roles.sql').write_bytes(postgres(['pg_dumpall', '--roles-only']))
        run(['tar', '-czf', str(destination / 'configuration.tar.gz'), *CONFIG_PATHS])
        listing = run(['pg_restore', '--list', str(destination / 'database.dump')])
        if b'pi_schema_migrations' not in listing or b'pi_resource' not in listing:
            raise RuntimeError('Backup table-of-contents check failed')
        package = json.loads(Path('/opt/process-intelligence/current/PACKAGE_MANIFEST.json').read_text())
        versions = postgres(['psql', '-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-d', DATABASE,
                             '-c', 'SELECT version FROM pi_schema_migrations ORDER BY version;'])
        files = [dict(name=path.name, bytes=path.stat().st_size, sha256=file_sha256(path))
                 for path in sorted(destination.iterdir())]
        result = dict(status='quiesced_database_backup_complete', timestamp=stamp,
                      source_commit=package['source_commit'], schema_versions=versions.decode().split(),
                      files=files, scope='Local database, cluster roles and configuration. '
                      'TOC checked; rehearse restore and copy off host separately.')
        (destination / 'manifest.json').write_text(json.dumps(result, indent=2) + '\n')
        for path in destination.iterdir():
            path.chmod(0o600)
        destination.rename(BACKUPS / stamp)
    finally:
        restart_if_needed()
    complete = sorted(path for path in BACKUPS.iterdir()
                      if path.is_dir() and not path.is_symlink()
                      and re.fullmatch(r'\d{8}T\d{6}Z', path.name)
                      and (path / 'manifest.json').is_file())
    for old in complete[:-KEEP]:
        if old.resolve().parent != BACKUPS.resolve():
            raise RuntimeError('Backup retention path escaped its directory')
        shutil.rmtree(old)
    return result


def main():
    if os.geteuid() != 0:
        raise RuntimeError('This backup service must run as root')
    os.umask(0o077)
    RUNTIME.mkdir(mode=0o700, exist_ok=True)
    BACKUPS.mkdir(mode=0o700, exist_ok=True)
    if sys.argv[1:] == ['restore-service']:
        restart_if_needed()
        return
    if sys.argv[1:]:
        raise RuntimeError('Only optional argument: restore-service')
    with (RUNTIME / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Preserve and recover a prior interrupted attempt before doing more work.
        restart_if_needed()
        print(json.dumps(backup()))


if __name__ == '__main__':
    main()
