#!/usr/bin/env python3
"""Lock-file gate: the iOS bridge must pin exactly the crate versions Android ships.

Compares ``clients/ios/bridge/Cargo.lock`` with ``clients/core/Cargo.lock``:

* every registry package ``(name, version, checksum)`` of the bridge lock must
  appear unchanged in the core lock, and every registry package of the core
  lock must appear in the bridge lock (same dependency set as Android);
* every path package of the core lock (``paranoid-client-core``,
  ``paranoid-key-protocol``) must be present in the bridge lock with the same
  version; the only extra path package allowed is the bridge itself.

Prints ``OK`` (exit 0) or one ``FAIL: ...`` line per mismatch (exit 1). Exit 2
when a lock file is missing or unreadable. Re-seed the bridge lock from the
core lock when this fails after a core bump (see clients/ios/README.md).
"""
import argparse
from pathlib import Path
import sys
import tomllib

HERE = Path(__file__).resolve().parent
CORE_LOCK = HERE.parent / 'core' / 'Cargo.lock'
BRIDGE_LOCK = HERE / 'bridge' / 'Cargo.lock'
BRIDGE_PACKAGE = 'paranoid-ios-bridge'


def load(path):
    try:
        with open(path, 'rb') as handle:
            return tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        print(f'ERROR: cannot read {path}: {error}', file=sys.stderr)
        sys.exit(2)


def split(lock):
    """Return (registry, path) maps keyed by package name."""
    registry, path_packages = {}, {}
    for package in lock.get('package', []):
        name, version = package['name'], package['version']
        if 'source' in package:
            registry.setdefault(name, set()).add((version, package.get('checksum'), package['source']))
        else:
            path_packages[name] = version
    return registry, path_packages


def describe(entry):
    version, checksum, source = entry
    return f'{version} checksum={checksum} source={source}'


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--core', type=Path, default=CORE_LOCK, help=f'core lock (default: {CORE_LOCK})')
    parser.add_argument('--bridge', type=Path, default=BRIDGE_LOCK, help=f'bridge lock (default: {BRIDGE_LOCK})')
    args = parser.parse_args()
    core, bridge = load(args.core), load(args.bridge)
    failures = []
    if core.get('version') != bridge.get('version'):
        failures.append(f'lock format differs: core version={core.get("version")} bridge version={bridge.get("version")}')
    core_registry, core_paths = split(core)
    bridge_registry, bridge_paths = split(bridge)
    for name, entries in sorted(bridge_registry.items()):
        for entry in sorted(entries, key=str):
            if entry not in core_registry.get(name, set()):
                expected = ', '.join(describe(e) for e in sorted(core_registry.get(name, set()), key=str)) or 'absent'
                failures.append(f'bridge pins {name} {describe(entry)} but core has {expected}')
    for name, entries in sorted(core_registry.items()):
        for entry in sorted(entries, key=str):
            if entry not in bridge_registry.get(name, set()):
                failures.append(f'core pins {name} {describe(entry)} but bridge lacks it')
    for name, version in sorted(core_paths.items()):
        if bridge_paths.get(name) != version:
            failures.append(f'path package {name} {version} missing or changed in bridge (found {bridge_paths.get(name)})')
    for name in sorted(set(bridge_paths) - set(core_paths) - {BRIDGE_PACKAGE}):
        failures.append(f'bridge adds unexpected path package {name}')
    if BRIDGE_PACKAGE not in bridge_paths:
        failures.append(f'bridge lock has no {BRIDGE_PACKAGE} package (seed it: cp core lock, build once without --locked)')
    for failure in failures:
        print(f'FAIL: {failure}')
    if failures:
        return 1
    registry_count = sum(len(entries) for entries in core_registry.values())
    print(f'OK: {registry_count} registry packages and {len(core_paths)} path packages match {args.core.name} of clients/core')
    return 0


if __name__ == '__main__':
    sys.exit(main())
