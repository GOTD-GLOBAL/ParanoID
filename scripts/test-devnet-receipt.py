"""Offline negative fixtures for the Devnet deployment citation gate."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import base64
import hashlib
import io
import json

spec=importlib.util.spec_from_file_location('gate',Path(__file__).with_name('check-devnet-receipt.py'))
assert spec is not None and spec.loader is not None
gate=importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

class ReceiptGateTest(unittest.TestCase):
    def test_rejects_unfinalized_deployment(self):
        with self.assertRaises(ValueError):
            gate.verify_status({'confirmationStatus':'confirmed','err':None,'slot':502240101})

    def test_program_authority_and_bytecode(self):
        loader='BPFLoaderUpgradeab1e11111111111111111111111'
        p=bytes([2,0,0,0])+base64.b64decode('JWY9XRDw+3elIwbt3hyMEQ6LYyvXj8Yb6HKt7rcPMtE=')
        d=bytes([3,0,0,0])+bytes(8)+bytes([1])+base64.b64decode('Rj7EwqG3Ted9Uycw3tEu/6sZhMVUHYCT9xhL64aDLMg=')+bytes(73800)
        def account(data,executable):
            return {'owner':loader,'executable':executable,'data':[base64.b64encode(data).decode(),'base64']}
        with patch.object(gate,'SBF_SHA',hashlib.sha256(d[45:]).hexdigest()):
            gate.verify_accounts([account(p,True),account(d,False)])
            bad=bytearray(d);bad[13]^=1
            with self.assertRaises(ValueError):gate.verify_accounts([account(p,True),account(bad,False)])
            for offset in [0,12,45,len(d)-1]:
                bad=bytearray(d);bad[offset]^=1
                with self.assertRaises(ValueError):gate.verify_accounts([account(p,True),account(bad,False)])
            for invalid in [[None,None],[],[account(p,False),account(d,False)],
                            [account(p,True),account(d,False)|{'owner':'11111111111111111111111111111111'}],
                            [account(p[:-1],True),account(d,False)],
                            [account(p,True),account(d[:-1],False)]]:
                with self.assertRaises(ValueError):gate.verify_accounts(invalid)
        gate.verify_status({'confirmationStatus':'finalized','err':None,'slot':502240101})
        for status in [None,{}, {'confirmationStatus':'finalized','err':{'InstructionError':[]},'slot':502240101},
                       {'confirmationStatus':'finalized','err':None,'slot':1}]:
            with self.assertRaises(ValueError):gate.verify_status(status)

    def test_wrong_network_stops_before_account_queries(self):
        calls=[]
        def rpc(method,params):
            calls.append(method)
            return 'mainnet'
        with self.assertRaises(ValueError):gate.check(rpc)
        self.assertEqual(calls,['getGenesisHash'])

    def test_live_path_rejects_absent_program(self):
        def rpc(method,params):
            if method=='getGenesisHash':return 'EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG'
            if method=='getMultipleAccounts':return {'value':[None,None]}
            raise AssertionError('unexpected method')
        with self.assertRaises(ValueError):gate.check(rpc)

    def test_live_path_requires_recorded_finalized_signature(self):
        calls=[]
        p=bytes([2,0,0,0])+base64.b64decode('JWY9XRDw+3elIwbt3hyMEQ6LYyvXj8Yb6HKt7rcPMtE=')
        d=bytes([3,0,0,0])+bytes(8)+bytes([1])+base64.b64decode('Rj7EwqG3Ted9Uycw3tEu/6sZhMVUHYCT9xhL64aDLMg=')+bytes(73800)
        accounts=[{'owner':'BPFLoaderUpgradeab1e11111111111111111111111','executable':flag,'data':[base64.b64encode(raw).decode(),'base64']} for raw,flag in [(p,True),(d,False)]]
        def rpc(method,params):
            calls.append((method,params))
            if method=='getGenesisHash':return 'EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG'
            if method=='getMultipleAccounts':return {'value':accounts}
            if method=='getSignatureStatuses':return {'value':[None]}
            raise AssertionError(method)
        with patch.object(gate,'SBF_SHA',hashlib.sha256(d[45:]).hexdigest()):
            with self.assertRaises(ValueError):gate.check(rpc)
        self.assertEqual(calls[-1][0],'getSignatureStatuses')
        self.assertEqual(calls[-1][1][1],{'searchTransactionHistory':True})

    def test_readonly_transport_rejects_submission(self):
        with self.assertRaises(ValueError):gate.rpc('sendTransaction',[])

    def test_transport_decodes_and_checks_response(self):
        with patch.object(gate.urllib.request,'build_opener') as opener:
            opener.return_value.open.return_value=io.BytesIO(json.dumps({'jsonrpc':'2.0','id':1,'result':'test-genesis'}).encode())
            self.assertEqual(gate.rpc('getGenesisHash',[]),'test-genesis')
            request=opener.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url,'https://api.devnet.solana.com')
            self.assertEqual(request.get_method(),'POST')
            for response in [{'jsonrpc':'2.0','id':2,'result':'bad'}, {'jsonrpc':'2.0','id':1,'error':{'code':429}}]:
                opener.return_value.open.return_value=io.BytesIO(json.dumps(response).encode())
                with self.assertRaises(ValueError):gate.rpc('getGenesisHash',[])
            opener.return_value.open.return_value=io.BytesIO(b'x'*262145)
            with self.assertRaises(ValueError):gate.rpc('getGenesisHash',[])

    def test_status_rejects_missing_error_field(self):
        with self.assertRaises(ValueError):gate.verify_status({'confirmationStatus':'finalized','slot':502240101})

    def test_ci_requires_rpc_gate_before_exact_browser_exceptions(self):
        workflow=(Path(__file__).resolve().parents[1]/'.github/workflows/docs.yml').read_text()
        self.assertIn('python3 scripts/check-devnet-receipt.py',workflow)
        self.assertIn('python3 scripts/test-devnet-receipt.py',workflow)
        self.assertLess(workflow.index('python3 scripts/check-devnet-receipt.py'),workflow.index('name: Check links'))
        lines=[line for line in workflow.splitlines() if '--exclude' in line and 'explorer' in line]
        self.assertEqual(len(lines),2)
        self.assertTrue(all('cluster=devnet$' in line for line in lines))
        self.assertFalse(any('--accept' in line for line in workflow.splitlines()))

if __name__=='__main__':unittest.main()
