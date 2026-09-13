"""Synthetic metadata/proof tests; no live paths, services or database actions."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('reconcile', Path(__file__).with_name('reconcile_apk_cap_20260913.py'))
assert spec is not None and spec.loader is not None
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)

class ReconcileTests(unittest.TestCase):
    def setUp(self):
        self.old = {'v': 1, 'phase': 'active', 'transaction': 'a'*32,
                    'intent': {'expected': {'original': 'kept'}}, 'acceptance_sha256': 'b'*64,
                    'message_result': {'identity': {k:k+'-old' for k in r.IDENTITY_FIELDS}}}
        self.live = copy.deepcopy(self.old['message_result']['identity'])
        for k in r.CHANGED_FIELDS:
            self.live[k] = k+'-new'
        self.targets = {k:self.live[k] for k in r.CHANGED_FIELDS}

    def test_exact_delta_annotated_without_rewriting_old_plan_or_acceptance(self):
        before = copy.deepcopy(self.old)
        after = r.annotate(self.old, self.live, self.targets, 'c'*64)
        self.assertEqual(self.old, before)
        self.assertEqual(after['intent'], before['intent'])
        self.assertEqual(after['acceptance_sha256'], before['acceptance_sha256'])
        self.assertEqual(after['transaction'], before['transaction'])
        self.assertEqual(after['message_result']['identity'], self.live)
        self.assertEqual(after['maintenance_adoptions'][0]['proof_sha256'], 'c'*64)

    def test_unexpected_identity_change_rejected(self):
        for key in set(r.IDENTITY_FIELDS)-set(r.CHANGED_FIELDS):
            live = dict(self.live); live[key] = 'foreign'
            with self.assertRaises(ValueError): r.annotate(self.old, live, self.targets, 'c'*64)

    def test_wrong_target_or_missing_delta_rejected(self):
        for key in r.CHANGED_FIELDS:
            for value in ['foreign', self.old['message_result']['identity'][key]]:
                live = dict(self.live); live[key] = value
                with self.assertRaises(ValueError): r.annotate(self.old, live, self.targets, 'c'*64)

    def test_inactive_or_previously_adopted_state_rejected(self):
        for key,value in [('phase','failed'),('maintenance_adoptions',[{}])]:
            old = copy.deepcopy(self.old); old[key] = value
            with self.assertRaises(ValueError): r.annotate(old, self.live, self.targets, 'c'*64)

    def fixture(self, root):
        before=r.canonical(self.old)
        after=r.canonical(r.annotate(self.old,self.live,self.targets,'c'*64))
        current=root/'current.json'; journal=root/'journal.json'
        current.write_bytes(before);journal.write_bytes(before)
        current.chmod(0o600);journal.chmod(0o600)
        return before,after,current,journal

    def test_empty_preparation_directory_resumes_from_exact_live_original(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); before,after,current,journal=self.fixture(root)
            audit=root/'audit';audit.mkdir(mode=0o700)
            self.assertEqual(r.select_before(audit,current,journal,r.sha(before)),before)
            r.persist(audit,current,journal,before,after,'c'*64)
            self.assertEqual(current.read_bytes(),after)

    def test_interrupted_image_publication_never_leaves_partial_final_image(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); before,after,current,journal=self.fixture(root)
            with patch.object(r,'publish_noreplace',side_effect=RuntimeError('before rename')):
                with self.assertRaises(RuntimeError):r.persist(root/'audit',current,journal,before,after,'c'*64)
            self.assertFalse((root/'audit/current.before').exists())
            self.assertEqual(r.select_before(root/'audit',current,journal,r.sha(before)),before)
            r.persist(root/'audit',current,journal,before,after,'c'*64)
            self.assertEqual(current.read_bytes(),after)

    def test_missing_before_image_cannot_adopt_foreign_or_partial_metadata(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); before,after,current,journal=self.fixture(root)
            audit=root/'audit';audit.mkdir(mode=0o700)
            journal.write_bytes(after)
            with self.assertRaises(ValueError):r.select_before(audit,current,journal,r.sha(before))
            current.write_bytes(after)
            with self.assertRaises(ValueError):r.select_before(audit,current,journal,r.sha(before))

    def test_before_images_preserved_and_repeat_idempotent(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); before,after,current,journal=self.fixture(root)
            for _ in range(2):r.persist(root/'audit',current,journal,before,after,'c'*64)
            self.assertEqual(current.read_bytes(),after);self.assertEqual(journal.read_bytes(),after)
            self.assertEqual((root/'audit/current.before').read_bytes(),before)
            self.assertEqual((root/'audit/journal.before').read_bytes(),before)
            self.assertEqual((root/'audit/current.before').stat().st_mode&0o777,0o400)

    def test_interruption_between_replacements_resumes_only_exact_images(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); before,after,current,journal=self.fixture(root)
            def fault():raise RuntimeError('injected interruption')
            with self.assertRaises(RuntimeError):r.persist(root/'audit',current,journal,before,after,'c'*64,after_journal=fault)
            self.assertEqual(current.read_bytes(),before);self.assertEqual(journal.read_bytes(),after)
            r.persist(root/'audit',current,journal,before,after,'c'*64)
            self.assertEqual(current.read_bytes(),after)

    def test_foreign_partial_state_and_tampered_audit_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); before,after,current,journal=self.fixture(root)
            journal.write_bytes(b'foreign')
            with self.assertRaises(ValueError):r.persist(root/'audit',current,journal,before,after,'c'*64)
            self.assertEqual(current.read_bytes(),before)
            journal.write_bytes(before)
            r.persist(root/'audit',current,journal,before,after,'c'*64)
            image=root/'audit/current.before'; image.chmod(0o600); image.write_bytes(b'tampered')
            with self.assertRaises(ValueError):r.persist(root/'audit',current,journal,before,after,'c'*64)

    def test_symlink_and_unsafe_metadata_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); before,after,current,journal=self.fixture(root)
            current.unlink(); current.symlink_to(journal)
            with self.assertRaises((ValueError,OSError)):r.persist(root/'audit',current,journal,before,after,'c'*64)
            current.unlink();current.write_bytes(before);current.chmod(0o666)
            with self.assertRaises(ValueError):r.persist(root/'audit',current,journal,before,after,'c'*64)

if __name__ == '__main__': unittest.main()
