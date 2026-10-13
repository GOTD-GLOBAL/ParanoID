#!/usr/bin/env python3
"""Negative fixtures for the RFC-0030 two-lock gate; no dependency resolution."""
import copy
import importlib.util
from pathlib import Path
import unittest
from typing import Any

HERE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("bridge_lock", HERE / "test_bridge_lock.py")
assert spec is not None and spec.loader is not None
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def registry(name, version):
    return dict(name=name, version=version, source="registry+https://github.com/rust-lang/crates.io-index",
                checksum="public-fixture-" + version)


def path(name, version="0.0.1"):
    return dict(name=name, version=version)


def lock(*packages) -> dict[str, Any]:
    return dict(version=4, package=list(packages))


class LockTest(unittest.TestCase):
    def setUp(self):
        self.core = lock(path("paranoid-client-core"), path("paranoid-key-protocol"),
                         registry("shared", "1.0.0"))
        self.devnet = lock(path("paranoid-devnet-client", "0.1.0"), path("paranoid-key-protocol"),
                           registry("shared", "2.0.0"), registry("extra", "1.0.0"))
        self.bridge = lock(*copy.deepcopy(self.core["package"]),
                           path("paranoid-ios-bridge"), path("paranoid-devnet-client", "0.1.0"),
                           registry("shared", "2.0.0"), registry("extra", "1.0.0"))

    def test_combined_graph_retains_core_and_adds_only_devnet_pins(self):
        self.assertEqual(gate.compare(self.core, self.devnet, self.bridge), [])

    def test_core_version_can_satisfy_devnet_without_keeping_its_other_version(self):
        self.bridge["package"].remove(registry("shared", "2.0.0"))
        self.assertEqual(gate.compare(self.core, self.devnet, self.bridge), [])

    def test_replacing_a_core_pin_with_a_devnet_pin_fails(self):
        self.bridge["package"].remove(registry("shared", "1.0.0"))
        self.assertTrue(gate.compare(self.core, self.devnet, self.bridge))

    def test_mutated_registry_name_version_checksum_or_source_fails(self):
        for name in ("shared", "extra"):
            for field in ("name", "version", "checksum", "source"):
                with self.subTest(name=name, field=field):
                    bad = copy.deepcopy(self.bridge)
                    next(p for p in bad["package"] if p["name"] == name)[field] = "changed"
                    self.assertTrue(gate.compare(self.core, self.devnet, bad))

    def test_missing_or_changed_required_path_packages_fail(self):
        for name in ("paranoid-client-core", "paranoid-key-protocol", "paranoid-devnet-client"):
            for changed in (True, False):
                with self.subTest(name=name, changed=changed):
                    bad = copy.deepcopy(self.bridge)
                    package = next(p for p in bad["package"] if p["name"] == name)
                    if changed:
                        package["version"] = "9.9.9"
                    else:
                        bad["package"].remove(package)
                    self.assertTrue(gate.compare(self.core, self.devnet, bad))

    def test_extra_path_package_is_not_permitted(self):
        self.bridge["package"].append(path("unexpected"))
        self.assertTrue(gate.compare(self.core, self.devnet, self.bridge))

    def test_bridge_package_must_exist(self):
        self.bridge["package"].remove(path("paranoid-ios-bridge"))
        failures = gate.compare(self.core, self.devnet, self.bridge)
        self.assertTrue(failures)
        self.assertIn("restore the reviewed combined lock", " ".join(failures))
        self.assertNotIn("cp core lock", " ".join(failures))

    def test_lock_format_must_match_core(self):
        self.bridge["version"] = 3
        self.assertTrue(gate.compare(self.core, self.devnet, self.bridge))

    def test_new_core_path_cannot_expand_the_four_package_allowlist(self):
        self.core["package"].append(path("unexpected"))
        self.bridge["package"].append(path("unexpected"))
        self.assertTrue(gate.compare(self.core, self.devnet, self.bridge))

    def test_duplicate_path_names_never_hide_earlier_versions(self):
        for which in ("core", "devnet", "bridge"):
            original = getattr(self, which)
            for item in [p for p in original["package"] if "source" not in p]:
                for version in (item["version"], "0.0.99"):
                    with self.subTest(lock=which, name=item["name"], version=version):
                        bad = copy.deepcopy(original)
                        bad["package"].insert(0, path(item["name"], version))
                        inputs = {"core": self.core, "devnet": self.devnet, "bridge": self.bridge}
                        inputs[which] = bad
                        failures = gate.compare(inputs["core"], inputs["devnet"], inputs["bridge"])
                        self.assertTrue(any("duplicate path package" in f for f in failures), failures)


if __name__ == "__main__":
    unittest.main()
