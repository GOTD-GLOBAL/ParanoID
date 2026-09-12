#!/usr/bin/env python3
"""Regression gates for the host artifact verifier, not Android execution."""
import unittest
import test_update_artifact as verifier


class PreviousArtifactPolicy(unittest.TestCase):
    def test_same_package_upgrade(self):
        verifier.validate_previous(
            {'package': 'global.paranoid.messenger', 'version_code': 15},
            {'package': 'global.paranoid.messenger', 'version_code': 14})

    def test_old_application_is_not_an_upgrade(self):
        with self.assertRaisesRegex(ValueError, 'same application package'):
            verifier.validate_previous(
                {'package': 'global.paranoid.messenger', 'version_code': 15},
                {'package': 'org.paranoid.devtext', 'version_code': 13})

    def test_equal_or_newer_previous_is_rejected(self):
        for version in (15, 16):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, 'older'):
                verifier.validate_previous(
                    {'package': 'global.paranoid.messenger', 'version_code': 15},
                    {'package': 'global.paranoid.messenger', 'version_code': version})


if __name__ == '__main__':
    unittest.main()
