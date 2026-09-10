#!/usr/bin/env python3
"""Offline regular-file TURN package integrity; never installs or starts services."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tarfile

MAX_FILE = 64 * 1024 * 1024
MAX_TOTAL = 128 * 1024 * 1024


def unique(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError('duplicate field')
        result[key] = value
    return result


def regular_bytes(path, limit=MAX_FILE):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        meta = os.fstat(stream.fileno())
        if (not stat.S_ISREG(meta.st_mode) or meta.st_nlink != 1
                or meta.st_uid not in (0, os.geteuid()) or meta.st_mode & 0o022
                or meta.st_size > limit):
            raise ValueError('trusted bounded regular file required')
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError('file exceeds bound')
        return data


def members(root):
    result = []
    for path in root.rglob('*'):
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise ValueError('regular package members required')
        result.append(path.relative_to(root).as_posix())
    return sorted(result)


def identity(hashes):
    return hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()[:20]


def write_manifest(root, provenance):
    hashes = {name: hashlib.sha256(regular_bytes(root / name)).hexdigest()
              for name in members(root) if name != 'manifest.json'}
    data = {'v': 1, 'release': identity(hashes), 'sha256': hashes, 'provenance': provenance}
    (root / 'manifest.json').write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
    return data


def verify(root):
    root = Path(root)
    for parent in (root, *root.parents):
        if not stat.S_ISDIR(parent.lstat().st_mode):
            raise ValueError('real package directory required')
    manifest = json.loads(regular_bytes(root / 'manifest.json', 65536), object_pairs_hook=unique)
    if (set(manifest) != {'v', 'release', 'sha256', 'provenance'}
            or type(manifest['v']) is not int or manifest['v'] != 1
            or not isinstance(manifest['sha256'], dict)):
        raise ValueError('invalid package manifest')
    hashes = manifest['sha256']
    if set(members(root)) != {*hashes, 'manifest.json'} or identity(hashes) != manifest['release']:
        raise ValueError('package members or identity differ')
    total = 0
    for name, expected in hashes.items():
        if (not re.fullmatch(r'[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*', name)
                or any(p in ('.', '..') for p in PurePosixPath(name).parts)
                or not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected)):
            raise ValueError('invalid package filename or hash')
        data = regular_bytes(root / name)
        total += len(data)
        if total > MAX_TOTAL or hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('package checksum or size differs')
    return manifest


def archive(root, target):
    verify(root)
    with tarfile.open(target, 'x') as tar:
        for name in members(root):
            info = tar.gettarinfo(root / name, arcname='release/' + name)
            info.uid = info.gid = info.mtime = 0
            info.uname = info.gname = ''
            info.mode = 0o755 if info.mode & 0o111 else 0o644
            with (root / name).open('rb') as source:
                tar.addfile(info, source)


def extract(source, destination):
    destination = Path(destination)
    if destination.exists():
        raise ValueError('new extraction directory required')
    with tarfile.open(source, 'r') as tar:
        entries = tar.getmembers()
        names = set()
        total = 0
        for entry in entries:
            path = PurePosixPath(entry.name)
            if (not entry.isfile() or entry.name in names or len(path.parts) < 2
                    or path.parts[0] != 'release' or any(p in ('.', '..') for p in path.parts)
                    or not re.fullmatch(r'release/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*', entry.name)
                    or entry.size < 0 or entry.size > MAX_FILE):
                raise ValueError('unsafe package member')
            names.add(entry.name)
            total += entry.size
        if total > MAX_TOTAL or len(entries) > 64:
            raise ValueError('package exceeds bound')
        destination.mkdir(mode=0o700)
        for entry in entries:
            path = destination.joinpath(*PurePosixPath(entry.name).parts[1:])
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('xb') as output, tar.extractfile(entry) as stream:
                shutil.copyfileobj(stream, output)
            path.chmod(0o755 if entry.mode & 0o111 else 0o644)
    verify(destination)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('release', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps({'verified_release': verify(args.release)['release']}))
    except (OSError, ValueError, TypeError, KeyError):
        raise SystemExit('TURN package verification failed') from None
