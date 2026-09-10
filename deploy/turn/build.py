#!/usr/bin/env python3
"""Build the pinned TURN package from supplied local archives; no deployment."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile

import package

HERE = Path(__file__).resolve().parent
LIBRARIES = ('libcrypto.so.3', 'libssl.so.3', 'libevent_core-2.1.so.7',
             'libevent_extra-2.1.so.7', 'libevent_openssl-2.1.so.7',
             'libevent_pthreads-2.1.so.7')


def run(command, log, **kwargs):
    subprocess.run([str(x) for x in command], stdout=log, stderr=log, check=True,
                   timeout=600, **kwargs)


def elf(path):
    dynamic = subprocess.check_output(['readelf', '-d', str(path)], text=True)
    versions = subprocess.check_output(['readelf', '--version-info', str(path)], text=True)
    headers = subprocess.check_output(['readelf', '-h', str(path)], text=True)
    if 'Advanced Micro Devices X86-64' not in headers or 'RPATH' in dynamic or 'RUNPATH' in dynamic:
        raise ValueError('unexpected architecture or runtime search path')
    needed = sorted(re.findall(r'\(NEEDED\).*\[(.*?)\]', dynamic))
    if set(needed) - {*LIBRARIES, 'libc.so.6', 'ld-linux-x86-64.so.2'}:
        raise ValueError('unexpected shared library dependency')
    return {'needed': needed, 'glibc_versions': sorted(set(re.findall(r'GLIBC_[0-9.]+', versions)))}


def main(inputs, output):
    if platform.machine() != 'x86_64' or not inputs.is_absolute() or not output.is_absolute():
        raise ValueError('absolute directories and Linux x86_64 required')
    pins = json.loads((HERE / 'inputs.json').read_text())
    # Check every immutable input before creating a build tree or invoking code.
    for item in pins['archives']:
        data = package.regular_bytes(inputs / item['file'])
        if len(data) != item['bytes'] or hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('pinned input differs')
    patch = package.regular_bytes(HERE / 'coturn-rest-expiry.patch')
    if hashlib.sha256(patch).hexdigest() != pins['patch_sha256']:
        raise ValueError('reviewed patch differs')
    if {p.name for p in (HERE / 'licenses').iterdir()} != set(pins['licenses_sha256']):
        raise ValueError('license inventory differs')
    for name, expected in pins['licenses_sha256'].items():
        if hashlib.sha256(package.regular_bytes(HERE / 'licenses' / name)).hexdigest() != expected:
            raise ValueError('pinned license notice differs')
    output.mkdir(mode=0o700)
    sysroot = output / 'sysroot'
    sysroot.mkdir()
    with (output / 'build.log').open('w') as log:
        for item in pins['archives']:
            if item['file'].endswith('.deb'):
                run(['dpkg-deb', '-x', inputs / item['file'], sysroot], log)
        source_archive = inputs / pins['archives'][0]['file']
        with tarfile.open(source_archive) as archive:
            members = archive.getmembers()
            if any(not (m.isfile() or m.isdir() or m.issym()) or (m.name != 'coturn-4.18.0' and not m.name.startswith('coturn-4.18.0/'))
                   or '..' in Path(m.name).parts for m in members):
                raise ValueError('unsafe source archive')
            # Upstream has example-certificate and man-page symlinks. They are
            # unnecessary for this executable build and never enter output.
            omitted_symlinks = [m.name for m in members if m.issym()]
            archive.extractall(output, members=[m for m in members if not m.issym()], filter='data')
        source = output / 'coturn-4.18.0'
        for name, expected in pins['source_before'].items():
            if hashlib.sha256((source / name).read_bytes()).hexdigest() != expected:
                raise ValueError('pristine source differs')
        run(['patch', '--batch', '--fuzz=0', '-p1', '-i', HERE / 'coturn-rest-expiry.patch'], log, cwd=source)
        for name, expected in pins['source_after'].items():
            if hashlib.sha256((source / name).read_bytes()).hexdigest() != expected:
                raise ValueError('patched source differs')
        lib = sysroot / 'usr/lib/x86_64-linux-gnu'
        env = {'PATH': str(sysroot / 'usr/bin') + ':/usr/bin:/bin', 'LANG': 'C', 'LD_LIBRARY_PATH': str(lib),
               'PKG_CONFIG': str(sysroot / 'usr/bin/pkgconf'),
               'PKG_CONFIG_LIBDIR': str(lib / 'pkgconfig'), 'PKG_CONFIG_SYSROOT_DIR': str(sysroot),
               'CFLAGS': f'-O2 -fPIE -fstack-protector-strong -I{sysroot}/usr/include -I{sysroot}/usr/include/x86_64-linux-gnu',
               'LDFLAGS': f'-L{lib} -Wl,-z,relro,-z,now'}
        for disabled in ('PQ', 'MYSQL', 'SQLITE', 'MONGO', 'HIREDIS', 'SYSTEMD', 'PROMETHEUS', 'SCTP'):
            env['TURN_NO_' + disabled] = '1'
        run(['./configure', '--prefix=/opt/paranoid-turn', '--disable-rpath'], log, cwd=source, env=env)
        run(['make', '-j2', 'bin/turnserver'], log, cwd=source, env=env)
    release = output / 'release'
    (release / 'bin').mkdir(parents=True)
    (release / 'lib').mkdir()
    (release / 'licenses').mkdir()
    shutil.copyfile(source / 'bin/turnserver', release / 'bin/turnserver')
    (release / 'bin/turnserver').chmod(0o755)
    for name in LIBRARIES:
        resolved = (lib / name).resolve(strict=True)
        if not resolved.is_relative_to(sysroot):
            raise ValueError('dependency escapes verified sysroot')
        shutil.copyfile(resolved, release / 'lib' / name)
    for name in ('runtime.py', 'package.py', 'turnserver.conf.in', 'paranoid-turn.service.in',
                 'README.md', 'inputs.json', 'coturn-rest-expiry.patch'):
        shutil.copyfile(HERE / name, release / name)
    for path in (HERE / 'licenses').glob('*.txt'):
        shutil.copyfile(path, release / 'licenses' / path.name)
    closure = {path.relative_to(release).as_posix(): elf(path)
               for path in [release / 'bin/turnserver', *(release / 'lib' / n for n in LIBRARIES)]}
    compiler = subprocess.check_output(['cc', '--version'], text=True).splitlines()[0]
    provenance = {'profile': 'paranoid-turn-v1', 'coturn': '4.18.0',
                  'omitted_source_symlinks': omitted_symlinks,
                  'inputs': pins, 'elf': closure, 'compiler': compiler,
                  'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=HERE, text=True).strip(),
                  'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=HERE)),
                  'acceptance': {'expiry_regression': 'NOT RUN', 'acl_packets': 'NOT RUN',
                                 'new_network_tests': 'NOT RUN', 'live_deployment': 'NOT AUTHORIZED'}}
    manifest = package.write_manifest(release, provenance)
    package.verify(release)
    artifact = output / ('paranoid-turn-' + manifest['release'] + '-linux-x86_64.tar')
    package.archive(release, artifact)
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    artifact.with_suffix('.tar.sha256').write_text(digest + '  ' + artifact.name + '\n')
    # Load and identify the exact relocated binary without starting any listener.
    relocated = output / 'relocated'
    package.extract(artifact, relocated)
    check_env = {'PATH': '/usr/bin:/bin', 'LANG': 'C', 'LD_LIBRARY_PATH': str(relocated / 'lib'),
                 'OPENSSL_CONF': '/dev/null'}
    version = subprocess.check_output([relocated / 'bin/turnserver', '--version'], env=check_env,
                                      text=True, timeout=10).strip()
    if version != '4.18.0':
        raise ValueError('packaged executable version mismatch')
    loader = subprocess.check_output(['/lib64/ld-linux-x86-64.so.2', '--library-path', str(relocated / 'lib'),
                                     '--list', str(relocated / 'bin/turnserver')], text=True, timeout=10)
    for name in LIBRARIES:
        if f'{name} => {relocated}/lib/{name}' not in loader:
            raise ValueError('runtime dependency does not resolve inside package')
    (output / 'offline-verification.json').write_text(json.dumps(
        {'artifact': str(artifact), 'sha256': digest, 'release': manifest['release'],
         'version': version, 'relocated_loader': loader, 'network_tests': 'NOT RUN'}, indent=2) + '\n')
    print(json.dumps({'artifact': str(artifact), 'sha256': digest, 'release': manifest['release']}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    main(args.inputs, args.output)
