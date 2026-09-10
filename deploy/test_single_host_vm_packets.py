"""Offline scope and evidence checks; no network/VM/relay operations."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import single_host_vm_packets as packets


class PacketEvidenceTests(unittest.TestCase):
    def test_only_fixed_owned_guest_endpoints_and_exact_fields_are_admitted(self):
        valid = {'mode': 'udp-send', 'target': 'local', 'marker': 'owned-' + 'a' * 32}
        self.assertEqual(packets.validate_request(valid), valid)
        for changed in ({**valid, 'host': 'example.org'}, {**valid, 'target': '169.254.169.254'},
                        {**valid, 'marker': 'unbounded'}, {**valid, 'mode': 'scan'}):
            with self.assertRaises(ValueError):
                packets.validate_request(changed)

    def test_silence_without_same_target_positive_control_is_never_denial_proof(self):
        good = {'positive_received': 1, 'negative_received': 0, 'positive_attempted': 1,
                'negative_attempted': 3, 'window_seconds': 1.0, 'same_target': True,
                'positive_uid': 1903, 'negative_uid': 1902, 'sink_exit': 0}
        self.assertTrue(packets.denial_observed(good))
        for delta in ({'positive_received': 0}, {'negative_received': 1}, {'negative_attempted': 0},
                      {'window_seconds': 0}, {'same_target': False}, {'negative_uid': 1903},
                      {'sink_exit': -9}):
            self.assertFalse(packets.denial_observed({**good, **delta}))

    def test_media_requires_decoded_opus_both_directions_and_actual_relay_pairs(self):
        good = {'peers': [{'frames': 50, 'samples': 48000, 'energy': 1.2, 'codec': 'audio/opus',
                          'local_type': 'relay', 'remote_type': 'relay',
                          'local_ip': packets.PUBLIC, 'remote_ip': packets.PUBLIC,
                          'local_port': 40000, 'remote_port': 40001} for _ in range(2)]}
        self.assertTrue(packets.media_observed(good))
        for delta in ({'frames': 0}, {'energy': 0}, {'local_type': 'host'},
                      {'remote_port': 40116}, {'codec': 'audio/PCMU'}):
            bad = {'peers': [good['peers'][0], {**good['peers'][1], **delta}]}
            self.assertFalse(packets.media_observed(bad))


if __name__ == '__main__':
    unittest.main()
