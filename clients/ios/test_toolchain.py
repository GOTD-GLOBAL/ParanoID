#!/usr/bin/env python3
"""Verify the local toolchain matches the pins in clients/ios/toolchain.json.

Offline; runs only version queries. Exit 0 and print ``OK`` when every pinned
tool matches; exit 1 with one readable ``FAIL:`` line per mismatch or missing
tool. ``--no-xcode`` skips only the xcodebuild/xcrun checks (Xcode, iOS SDK,
Swift) and the PostgreSQL ``pg_bin`` check so the Rust and OpenSSL pins can be
verified on a Linux CI runner. Observed versions are written to
``out/evidence/toolchain.json`` (relative to this directory) on every run.

Run through ``clients/ios/toolchain.sh`` so the rustup proxies in ~/.cargo/bin
are on PATH in non-interactive shells.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
PIN_FILE = HERE / 'toolchain.json'
DEFAULT_EVIDENCE = HERE / 'out/evidence/toolchain.json'
REQUIRED_PINS = ('xcode', 'xcode_build', 'ios_sdk', 'swift', 'rust', 'rust_targets', 'pg_bin')
RUST_HINT = ('run through clients/ios/toolchain.sh (adds ~/.cargo/bin to PATH) '
             'or install rustup toolchain 1.98.1')


def run(argv, timeout=120):
    """Return (stdout, None) on success or (None, reason) when the tool is missing or fails."""
    if shutil.which(argv[0]) is None:
        return None, f'{argv[0]} not found on PATH'
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return None, f'{" ".join(argv)} timed out after {timeout}s'
    except OSError as error:
        return None, f'{" ".join(argv)} could not start: {error}'
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip().splitlines()
        return None, f'{" ".join(argv)} exited {completed.returncode}: {detail[0] if detail else "no output"}'
    return completed.stdout, None


class Report:
    def __init__(self):
        self.observed = {}
        self.failures = []
        self.skipped = []

    def ok(self, name, value):
        self.observed[name] = value
        print(f'{name}: {value}')

    def fail(self, name, message, value=None):
        if value is not None:
            self.observed[name] = value
        self.failures.append(f'{name}: {message}')
        print(f'FAIL: {name}: {message}')

    def skip(self, name, reason):
        self.skipped.append(name)
        print(f'skip {name} ({reason})')


def check_xcode(pins, report):
    output, error = run(['xcodebuild', '-version'])
    if error:
        report.fail('xcode', error)
        return
    version = re.search(r'^Xcode (\S+)', output, re.M)
    build = re.search(r'^Build version (\S+)', output, re.M)
    observed = {'xcode': version.group(1) if version else None, 'xcode_build': build.group(1) if build else None}
    if observed['xcode'] != pins['xcode'] or observed['xcode_build'] != pins['xcode_build']:
        report.fail('xcode', f'expected {pins["xcode"]} ({pins["xcode_build"]}), got '
                    f'{observed["xcode"]} ({observed["xcode_build"]})', observed)
        return
    report.ok('xcode', f'{observed["xcode"]} ({observed["xcode_build"]})')
    report.observed['xcode_build'] = observed['xcode_build']


def check_ios_sdk(pins, report):
    output, error = run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'])
    if error:
        report.fail('ios_sdk', error)
        return
    observed = output.strip()
    if observed != pins['ios_sdk']:
        report.fail('ios_sdk', f'expected {pins["ios_sdk"]}, got {observed}', observed)
        return
    report.ok('ios_sdk', observed)


def check_swift(pins, report):
    output, error = run(['xcrun', 'swift', '--version'])
    if error:
        report.fail('swift', error)
        return
    match = re.search(r'Apple Swift version (\S+)', output)
    observed = match.group(1) if match else output.strip().splitlines()[0]
    if observed != pins['swift']:
        report.fail('swift', f'expected {pins["swift"]}, got {observed}', observed)
        return
    report.ok('swift', observed)


def check_rustc(pins, report):
    output, error = run(['rustc', f'+{pins["rust"]}', '--version'])
    if error:
        report.fail('rustc', f'{error}; {RUST_HINT}')
        return
    observed = output.strip()
    if not observed.startswith(f'rustc {pins["rust"]} '):
        report.fail('rustc', f'expected rustc {pins["rust"]}, got {observed}', observed)
        return
    report.ok('rustc', observed)


def check_rust_targets(pins, report):
    output, error = run(['rustup', f'+{pins["rust"]}', 'target', 'list', '--installed'])
    if error:
        report.fail('rust_targets', f'{error}; {RUST_HINT}')
        return
    installed = sorted(line.strip() for line in output.splitlines() if line.strip())
    missing = [target for target in pins['rust_targets'] if target not in installed]
    if missing:
        report.fail('rust_targets', f'missing installed targets for rustup {pins["rust"]}: {", ".join(missing)} '
                    f'(rustup +{pins["rust"]} target add {" ".join(missing)})', installed)
        return
    report.ok('rust_targets', ', '.join(pins['rust_targets']))
    report.observed['rust_targets'] = installed


def check_openssl(report):
    output, error = run(['openssl', 'version'])
    if error:
        report.fail('openssl', error)
        return
    observed = output.strip()
    if not observed.startswith('OpenSSL 3'):
        report.fail('openssl', f'expected OpenSSL 3.x (LibreSSL lacks -addext used by TLS fixtures), got {observed}',
                    observed)
        return
    report.ok('openssl', observed)


def check_pg_bin(pins, report):
    pg_bin = Path(pins['pg_bin'])
    missing = [name for name in ('initdb', 'postgres', 'psql') if not (pg_bin / name).is_file()]
    if missing:
        report.fail('pg_bin', f'{pg_bin} is missing {", ".join(missing)}', str(pg_bin))
        return
    output, error = run([str(pg_bin / 'postgres'), '--version'])
    if error:
        report.fail('pg_bin', error, str(pg_bin))
        return
    observed = output.strip()
    if not re.match(r'^postgres \(PostgreSQL\) 16\.', observed):
        report.fail('pg_bin', f'expected PostgreSQL 16 in {pg_bin}, got {observed}', observed)
        return
    report.ok('pg_bin', f'{pg_bin} ({observed})')


def load_pins():
    try:
        pins = json.loads(PIN_FILE.read_text())
    except (OSError, ValueError) as error:
        raise SystemExit(f'FAIL: cannot read {PIN_FILE}: {error}')
    missing = [key for key in REQUIRED_PINS if key not in pins]
    if missing:
        raise SystemExit(f'FAIL: {PIN_FILE} lacks required keys: {", ".join(missing)}')
    return pins


def write_evidence(path, pins, report, result):
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        'checked_at': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'pinned': pins,
        'observed': report.observed,
        'skipped': report.skipped,
        'failures': report.failures,
        'result': result,
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--no-xcode', action='store_true',
                        help='skip only the xcodebuild/xcrun (Xcode, SDK, Swift) and pg_bin checks')
    parser.add_argument('--evidence', type=Path, default=DEFAULT_EVIDENCE,
                        help=f'where to write observed versions (default: {DEFAULT_EVIDENCE})')
    args = parser.parse_args()
    pins = load_pins()
    report = Report()
    if args.no_xcode:
        for name in ('xcode', 'ios_sdk', 'swift', 'pg_bin'):
            report.skip(name, '--no-xcode')
    else:
        check_xcode(pins, report)
        check_ios_sdk(pins, report)
        check_swift(pins, report)
    check_rustc(pins, report)
    check_rust_targets(pins, report)
    check_openssl(report)
    if not args.no_xcode:
        check_pg_bin(pins, report)
    result = 'FAIL' if report.failures else 'OK'
    write_evidence(args.evidence, pins, report, result)
    if report.failures:
        print(f'FAIL: {len(report.failures)} toolchain check(s) failed; evidence: {args.evidence}')
        return 1
    print('OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
