#!/usr/bin/env python3
"""Validated TURN credential launcher. Check mode never starts the server."""
import argparse
from contextlib import ExitStack
import ctypes
import hashlib
import os
from pathlib import Path
import re
import stat
import struct
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


def _metadata_identity(meta):
    return tuple(getattr(meta, name) for name in (
        'st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_nlink',
        'st_size', 'st_ctime_ns'))


def _read_acl(fd):
    """Recognize only the fixed Linux ACL ABI; never discover/reallocate size."""
    try:
        getter = ctypes.CDLL(None, use_errno=True).fgetxattr
    except (AttributeError, OSError):
        raise ValueError('runtime ACL capability unavailable') from None
    getter.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t]
    getter.restype = ctypes.c_ssize_t
    buffer = ctypes.create_string_buffer(44)
    if getter(fd, b'system.posix_acl_access', buffer, 44) != 44:
        raise ValueError('exact runtime ACL required')
    return buffer.raw


def _require_acl(fd, uid, permission):
    raw = _read_acl(fd)
    if len(raw) != 44 or struct.unpack_from('<I', raw)[0] != 2:
        raise ValueError('exact runtime ACL required')
    entries = tuple(struct.unpack_from('<HHI', raw, 4 + 8*i) for i in range(5))
    if entries != ((1, permission, 0xffffffff), (2, permission, uid),
                   (4, 0, 0xffffffff), (16, permission, 0xffffffff),
                   (32, 0, 0xffffffff)):
        raise ValueError('exact runtime ACL required')


def _open_child_directory(parent, component):
    if (not isinstance(component, str) or not component or '/' in component
            or component in ('.', '..')):
        raise ValueError('single directory component required')
    return os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                   | os.O_CLOEXEC, dir_fd=parent)


def _require_trusted_ancestor(fd):
    meta = os.fstat(fd)
    if (not stat.S_ISDIR(meta.st_mode) or meta.st_uid != 0
            or stat.S_IMODE(meta.st_mode) & 0o7022):
        raise ValueError('trusted runtime ancestor required')


def _read_systemd_copy(directory_fd, uid):
    """Private descriptor primitive, not an alternate production pathname API."""
    if type(uid) is not int or not 0 < uid < 0xffffffff:
        raise ValueError('dedicated runtime identity required')
    directory = os.fstat(directory_fd)
    if not stat.S_ISDIR(directory.st_mode):
        raise ValueError('private runtime credential directory required')
    mode = stat.S_IMODE(directory.st_mode)
    if directory.st_uid == uid and mode == 0o500:
        # A zero group mask denies every non-owner ACL grant without an ACL call.
        acl_layout = False
    elif directory.st_uid == 0 and mode == 0o550:
        acl_layout = True
        _require_acl(directory_fd, uid, 5)
    else:
        raise ValueError('private runtime credential directory required')
    fd = os.open('voice-turn-secret', os.O_RDONLY | os.O_NOFOLLOW
                 | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory_fd)
    try:
        meta = os.fstat(fd)
        if (not stat.S_ISREG(meta.st_mode) or meta.st_nlink != 1 or meta.st_size != 64
                or meta.st_uid != (0 if acl_layout else uid)
                or stat.S_IMODE(meta.st_mode) != (0o440 if acl_layout else 0o400)):
            raise ValueError('private runtime credential file required')
        if acl_layout:
            _require_acl(fd, uid, 4)
        value = os.read(fd, 65)
        if (_metadata_identity(meta) != _metadata_identity(os.fstat(fd))
                or _metadata_identity(directory) != _metadata_identity(os.fstat(directory_fd))):
            raise ValueError('runtime credential metadata changed')
        if not re.fullmatch(b'[0-9a-f]{64}', value):
            raise ValueError('invalid credential format')
        return value.decode('ascii')
    finally:
        os.close(fd)


def read_systemd_secret():
    """Only the fixed production system unit may use the ACL-aware reader."""
    uid = os.geteuid()
    if (not 0 < uid < 0xffffffff
            or os.environ.get('CREDENTIALS_DIRECTORY') != '/run/credentials/paranoid-turn.service'
            or os.environ.get('RUNTIME_DIRECTORY') != '/run/paranoid-turn'):
        raise ValueError('dedicated runtime identity and paths required')
    with ExitStack() as descriptors:
        fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        descriptors.callback(os.close, fd)
        _require_trusted_ancestor(fd)
        for component in ('run', 'credentials'):
            fd = _open_child_directory(fd, component)
            descriptors.callback(os.close, fd)
            _require_trusted_ancestor(fd)
        fd = _open_child_directory(fd, 'paranoid-turn.service')
        descriptors.callback(os.close, fd)
        return _read_systemd_copy(fd, uid)


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
    secret = read_systemd_secret()
    directory = Path('/run/paranoid-turn')
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
