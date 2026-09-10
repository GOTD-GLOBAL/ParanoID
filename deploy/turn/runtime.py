#!/usr/bin/env python3
"""Validated TURN credential launcher. Check mode never starts the server."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import package


def read_secret(path):
    path = Path(path)
    if not path.is_absolute():
        raise ValueError('absolute credential path required')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        meta = os.fstat(stream.fileno())
        if (not stat.S_ISREG(meta.st_mode) or meta.st_nlink != 1
                or meta.st_uid not in (0, os.geteuid())
                or stat.S_IMODE(meta.st_mode) not in (0o400, 0o600)):
            raise ValueError('private credential file required')
        value = stream.read(65)
    if not re.fullmatch(b'[0-9a-f]{64}', value):
        raise ValueError('invalid credential format')
    return value.decode('ascii')


def render_config(template, secret, directory):
    # Pin the complete reviewed option set, including duplicate-sensitive lines.
    if hashlib.sha256(template.encode()).hexdigest() != TEMPLATE_SHA256:
        raise ValueError('unreviewed TURN configuration')
    if (not re.fullmatch(r'[0-9a-f]{64}', secret)
            or not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(directory))
            or '..' in directory.parts):
        raise ValueError('invalid runtime configuration input')
    return template.replace('@SECRET@', secret).replace('@RUNTIME@', str(directory))


def write_config(directory, content):
    directory = Path(directory)
    meta = directory.lstat()
    if (not stat.S_ISDIR(meta.st_mode) or meta.st_uid != os.geteuid()
            or stat.S_IMODE(meta.st_mode) != 0o700):
        raise ValueError('private owned runtime directory required')
    target = directory / 'turnserver.conf'
    if target.exists() or target.is_symlink():
        old = target.lstat()
        if (not stat.S_ISREG(old.st_mode) or old.st_nlink != 1
                or old.st_uid != os.geteuid() or stat.S_IMODE(old.st_mode) != 0o600):
            raise ValueError('unsafe existing runtime config')
    fd, temporary = tempfile.mkstemp(prefix='.turn-config-', dir=directory)
    try:
        with os.fdopen(fd, 'w') as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return target


def child_environment(release):
    return {'PATH': '/usr/bin:/bin', 'LANG': 'C',
            'LD_LIBRARY_PATH': str(release / 'lib'), 'OPENSSL_CONF': '/dev/null'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('check', 'run'))
    args = parser.parse_args()
    release = Path(__file__).resolve().parent
    manifest = package.verify(release)
    if manifest['provenance'].get('profile') != 'paranoid-turn-v1':
        raise ValueError('unexpected TURN profile')
    credentials = Path(os.environ['CREDENTIALS_DIRECTORY'])
    directory = Path(os.environ['RUNTIME_DIRECTORY'])
    if (not credentials.is_absolute() or directory != Path('/run/paranoid-turn')
            or os.geteuid() == 0):
        raise ValueError('dedicated runtime identity and paths required')
    secret = read_secret(credentials / 'voice-turn-secret')
    content = render_config((release / 'turnserver.conf.in').read_text(), secret, directory)
    if args.operation == 'check':
        print('TURN package and credential configuration valid; listener not started')
        return
    config = write_config(directory, content)
    # Dedicated unit suppresses raw output too; no credential value is passed.
    null = os.open('/dev/null', os.O_RDWR)
    os.dup2(null, 1)
    os.dup2(null, 2)
    os.close(null)
    os.execve(release / 'bin/turnserver', ['turnserver', '-c', str(config)], child_environment(release))


TEMPLATE_SHA256 = 'a328a79f39e76569ee0ad7499b0f189880ab5c09ea03428b736d83600e46712e'

if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError):
        print('TURN launcher failed validation', file=sys.stderr)
        raise SystemExit(1) from None
