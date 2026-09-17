#!/usr/bin/env python3
"""Single component-boundary gate for the iOS client branch (offline, git only).

Inspects ``$(git merge-base <base> HEAD)..HEAD`` (committed changes only) and
fails when the branch touches a forbidden component or anything outside the
iOS allowlist. This is the only boundary check; CI and the handoff checkpoints
call it with ``--base <pull-request base sha>``.

Exit codes:
  0  ``PASS: N files changed, 0 outside allowlist``
  1  at least one forbidden or non-allowlisted path (each one is listed)
  2  git unavailable, not a repository, or ``<base>`` does not resolve
     (never a vacuous PASS)
"""
import argparse
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
DEFAULT_BASE = 'origin/main'
FORBIDDEN = ('server/', 'clients/core/src/', 'clients/android/', 'key-protocol/', 'deploy/')
ALLOWED_DIRS = ('clients/ios/', 'docs/')
ALLOWED_FILES = ('README.md', 'CHANGELOG.md', '.github/workflows/ios.yml', '.github/workflows/docs.yml')


def unavailable(message):
    print(f'ERROR: {message}', file=sys.stderr)
    sys.exit(2)


def git(*args):
    """Run git inside the repository; exit 2 on any failure (no vacuous PASS)."""
    argv = ['git', '-C', str(HERE), *args]
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, check=False)
    except OSError as error:
        unavailable(f'git is not available: {error}')
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or f'exit {completed.returncode}'
        unavailable(f'{" ".join(argv[3:])} failed: {detail}')
    return completed.stdout


def resolve_commit(ref, label):
    argv = ['git', '-C', str(HERE), 'rev-parse', '--verify', '--quiet', f'{ref}^{{commit}}']
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, check=False)
    except OSError as error:
        unavailable(f'git is not available: {error}')
    if completed.returncode != 0:
        unavailable(f'{label} {ref!r} does not resolve to a commit (fetch it or pass --base <ref|sha>)')
    return completed.stdout.strip()


def is_allowed(path):
    return path.startswith(ALLOWED_DIRS) or path in ALLOWED_FILES


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--base', default=DEFAULT_BASE,
                        help=f'ref or sha the branch forked from (default: {DEFAULT_BASE})')
    args = parser.parse_args()
    git('rev-parse', '--show-toplevel')
    base = resolve_commit(args.base, 'base')
    head = resolve_commit('HEAD', 'head')
    merge_base = git('merge-base', base, head).strip()
    print(f'base: {args.base} ({base[:12]}), merge-base: {merge_base[:12]}, head: {head[:12]}')
    files = sorted(path for path in git('diff', '--name-only', '--no-renames', '-z', merge_base, head).split('\0') if path)
    uncommitted = [entry for entry in git('status', '--porcelain', '-z').split('\0') if entry]
    if uncommitted:
        print(f'note: {len(uncommitted)} uncommitted change(s) are not part of this gate')
    forbidden = [path for path in files if path.startswith(FORBIDDEN)]
    outside = [path for path in files if not is_allowed(path) and path not in forbidden]
    for path in forbidden:
        print(f'forbidden: {path}')
    for path in outside:
        print(f'outside allowlist: {path}')
    violations = len(forbidden) + len(outside)
    if violations:
        print(f'FAIL: {len(files)} files changed, {violations} outside allowlist')
        return 1
    print(f'PASS: {len(files)} files changed, 0 outside allowlist')
    return 0


if __name__ == '__main__':
    sys.exit(main())
