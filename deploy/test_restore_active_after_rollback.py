import copy
import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('restore_active',Path(__file__).with_name('restore_active_after_rollback.py'))
assert spec and spec.loader
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class RestoredBaseline(unittest.TestCase):
    def setUp(self):
        self.identity={'release':'old','pg_system_id':'same','tls_spki':'same'}
        self.previous={'phase':'active','transaction':'prior','message_result':{'identity':self.identity}}
        self.failed={'phase':'rolled-back','transaction':'failed','previous_transaction':'prior','message_attempted':True,'message_result':None}
        self.child={'phase':'rolled-back','identity':self.identity}

    def test_exact_restored_predecessor_only_and_input_unchanged(self):
        old=copy.deepcopy(self.previous)
        self.assertEqual(m.validate_restored(self.failed,self.previous,self.child,self.identity),self.previous)
        self.assertEqual(old,self.previous)

    def test_unknown_phase_predecessor_or_runtime_is_rejected(self):
        cases=[('phase','active'),('phase','failed-stopped'),('previous_transaction','other'),('message_attempted',False),('message_result',{'identity':self.identity})]
        for key,value in cases:
            f=dict(self.failed);f[key]=value
            with self.assertRaises(ValueError):m.validate_restored(f,self.previous,self.child,self.identity)
        for arg in ['previous','child','identity']:
            previous=copy.deepcopy(self.previous);child=copy.deepcopy(self.child);identity=dict(self.identity)
            if arg=='previous':previous['phase']='rolled-back'
            if arg=='child':child['phase']='failed-stopped'
            if arg=='identity':identity['tls_spki']='different'
            with self.assertRaises(ValueError):m.validate_restored(self.failed,previous,child,identity)

if __name__=='__main__':unittest.main()
