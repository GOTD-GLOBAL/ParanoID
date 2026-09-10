#!/usr/bin/env python3
"""Build a new offline coordinated kit from exact retained components; no services."""
import argparse
from pathlib import Path
import sys
import tarfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import single_host as kit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=(kit.PRODUCTION, kit.FIXTURE, kit.VM_FIXTURE), required=True)
    parser.add_argument('--message', type=Path, required=True)
    parser.add_argument('--relay', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(mode=0o700)
    release = args.output / 'release'
    manifest = kit.build_kit(args.profile, args.message, args.relay, release)
    artifact = args.output / ('paranoid-single-host-' + manifest['release'] + '.tar')
    with tarfile.open(artifact, 'x') as archive:
        for directory in [release, *sorted(p for p in release.rglob('*') if p.is_dir())]:
            name = 'release' if directory == release else 'release/' + directory.relative_to(release).as_posix()
            info = tarfile.TarInfo(name)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            info.uid = info.gid = info.mtime = 0
            archive.addfile(info)
        for name in kit.tree_files(release):
            source = release / name
            info = archive.gettarinfo(source, arcname='release/' + name)
            info.uid = info.gid = info.mtime = 0
            info.uname = info.gname = ''
            info.mode = 0o755 if source.stat().st_mode & 0o111 else 0o644
            with source.open('rb') as stream:
                archive.addfile(info, stream)
    digest = kit.sha(kit.read_file(artifact))
    kit.atomic_write(artifact.with_suffix('.tar.sha256'),
                     (digest + '  ' + artifact.name + '\n').encode(), exclusive=True)
    print(kit.canonical({'artifact': str(artifact), 'sha256': digest,
                         'kit_manifest_sha256': kit.sha(kit.read_file(release / 'manifest.json')),
                         'profile': args.profile, 'release': manifest['release']}).decode(), end='')


if __name__ == '__main__':
    main()
