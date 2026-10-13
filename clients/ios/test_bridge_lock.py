#!/usr/bin/env python3
"""RFC-0030 bridge-lock gate: preserve core pins, add only Devnet-lock pins.

Every core entry remains with the same name/version/source/checksum. Every
additional registry entry must match blockchain/solana/client/Cargo.lock.
Only core, key-protocol, Devnet and bridge path packages are permitted.
This local candidate is not architecture acceptance; see
 docs/clients/ios/devnet-bridge.md for resolution and verification commands.

Exit 0 on success, 1 on mismatch, 2 on unreadable input. Never update either
shared lock to make this gate pass.
"""
import argparse
from pathlib import Path
import sys
import tomllib

HERE = Path(__file__).resolve().parent
CORE_LOCK = HERE.parent / 'core' / 'Cargo.lock'
BRIDGE_LOCK = HERE / 'bridge' / 'Cargo.lock'
BRIDGE_PACKAGE = 'paranoid-ios-bridge'
DEVNET_PACKAGE = 'paranoid-devnet-client'
DEVNET_LOCK = HERE.parents[1] / 'blockchain' / 'solana' / 'client' / 'Cargo.lock'


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


def compare(core, devnet, bridge):
    """Compare package identities, not dependency edges changed by unification."""
    failures = []
    if core.get('version') != bridge.get('version'):
        failures.append(f'lock format differs: core version={core.get("version")} bridge version={bridge.get("version")}')
    core_registry, core_paths = split(core)
    devnet_registry, devnet_paths = split(devnet)
    bridge_registry, bridge_paths = split(bridge)
    for name, entries in sorted(bridge_registry.items()):
        for entry in sorted(entries, key=str):
            if entry not in core_registry.get(name, set()) | devnet_registry.get(name, set()):
                failures.append(f'bridge pins {name} {describe(entry)} absent from core and Devnet locks')
    for name, entries in sorted(core_registry.items()):
        for entry in sorted(entries, key=str):
            if entry not in bridge_registry.get(name, set()):
                failures.append(f'core pins {name} {describe(entry)} but bridge lacks it')
    for name, version in sorted(core_paths.items()):
        if bridge_paths.get(name) != version:
            failures.append(f'path package {name} {version} missing or changed in bridge (found {bridge_paths.get(name)})')
    if bridge_paths.get(DEVNET_PACKAGE) != devnet_paths.get(DEVNET_PACKAGE) or DEVNET_PACKAGE not in bridge_paths:
        failures.append('Devnet path package missing or changed in bridge')
    allowed_paths = {'paranoid-client-core', 'paranoid-key-protocol', DEVNET_PACKAGE, BRIDGE_PACKAGE}
    for name in sorted(set(bridge_paths) - allowed_paths):
        failures.append(f'bridge adds unexpected path package {name}')
    if BRIDGE_PACKAGE not in bridge_paths:
        failures.append(f'bridge lock has no {BRIDGE_PACKAGE} package (seed it: cp core lock, build once without --locked)')
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--core', type=Path, default=CORE_LOCK)
    parser.add_argument('--devnet', type=Path, default=DEVNET_LOCK)
    parser.add_argument('--bridge', type=Path, default=BRIDGE_LOCK)
    args = parser.parse_args()
    core, devnet, bridge = load(args.core), load(args.devnet), load(args.bridge)
    failures = compare(core, devnet, bridge)
    for failure in failures:
        print(f'FAIL: {failure}')
    if failures:
        return 1
    core_registry, core_paths = split(core)
    bridge_registry, bridge_paths = split(bridge)
    core_count = sum(map(len, core_registry.values()))
    bridge_count = sum(map(len, bridge_registry.values()))
    print(f'OK: all {core_count} core registry pins and {len(core_paths)} core paths retained; '
          f'{bridge_count - core_count} added registry pins match Devnet; {len(bridge_paths)} path packages')
    return 0


if __name__ == '__main__':
    sys.exit(main())
