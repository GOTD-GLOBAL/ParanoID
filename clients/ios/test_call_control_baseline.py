#!/usr/bin/env python3
"""Mac-only C1 behavioral RED on disposable cb52330, never the active checkout.

Copies only the new regression into the old tree. Its test-only compatibility
extensions map new signatures to the old shipped unbound actions; production
baseline sources and all assertions are unchanged. A compiler failure is NOT RED.
Uses existing pinned framework directories read-only, no network/install/reset.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

BASE = 'cb523306c186e91a6d65e4050bd0b65eb9c7ab77'
ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path('clients/ios/ParanoidKit')
TEST = Path('Tests/ParanoidKitTests/CallControlDispatchTests.swift')


def behavioral_red(output, exit_code):
    return (exit_code != 0
            and "Test Suite 'CallControlDispatchTests' failed" in output
            and 'stale control must not change B' in output
            and re.search(r'Executed [1-9][0-9]* tests?, with [1-9][0-9]* failures? \(0 unexpected\)', output) is not None
            and not re.search(r'error: fatalError|error: emit-module command failed|Fatal error:|Exited with unexpected signal', output))


def main():
    if sys.platform != 'darwin' or shutil.which('swift') is None:
        raise SystemExit('NOT RUN: behavioral baseline requires the Mac Swift toolchain')
    binaries = ROOT / PACKAGE / 'Binaries'
    frameworks = ['ParanoidCore.xcframework', 'WebRTC.xcframework']
    for name in frameworks:
        if not (binaries / name).is_dir():
            raise SystemExit(f'Missing pinned build input: {binaries / name}')
    subprocess.run(['git', 'cat-file', '-e', BASE + '^{commit}'], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix='paranoid-c1-red-') as temporary:
        worktree = Path(temporary) / 'baseline'
        added = False
        try:
            subprocess.run(['git', 'worktree', 'add', '--detach', str(worktree), BASE],
                           cwd=ROOT, check=True)
            added = True
            package = worktree / PACKAGE
            (package / 'Binaries').mkdir(exist_ok=True)
            for name in frameworks:
                (package / 'Binaries' / name).symlink_to((binaries / name).resolve(), target_is_directory=True)
            shutil.copy2(ROOT / PACKAGE / TEST, package / TEST)
            command = ['swift', 'test', '--package-path', str(package),
                       '--scratch-path', str(Path(temporary) / 'spm'),
                       '-Xswiftc', '-DC1_LEGACY_BASELINE', '--filter', 'CallControlDispatchTests']
            print('BASELINE:', BASE, flush=True)
            print('COMMAND:', ' '.join(command), flush=True)
            result = subprocess.run(command, cwd=worktree, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, timeout=600)
            print(result.stdout, end='', flush=True)
            print('BASELINE SWIFT EXIT:', result.returncode, flush=True)
            if not behavioral_red(result.stdout, result.returncode):
                raise SystemExit('FAIL: behavioral RED not established (compile/setup failure is not RED)')
            print('PASS: expected behavioral RED against old unbound controls; current-SHA GREEN is separate')
        finally:
            if added:
                # Only the worktree created above, including its copied test.
                subprocess.run(['git', 'worktree', 'remove', '--force', str(worktree)],
                               cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
