#!/usr/bin/env python3
"""One-off acknowledgment of a verified completed rollback; metadata pointer only."""
import argparse
import copy
import fcntl
import json
import os
from pathlib import Path
import stat
import sys
import reconcile_apk_cap_20260913 as r

STATE=Path('/var/lib/paranoid-single-host')
ROOT=Path('/home/paranoid/paranoid-alpha')
FAILED='8bbb341ef62a6d5440048983ce5367fe'
PREVIOUS='cb52e2ed5f6ff678998cb26eb7fa0725'
FAILED_SHA='dea8c628d99b6aec5dd53de1e63f7ee8abcf20649843079bbeb5cea820cda238'
PREVIOUS_SHA='568882a05262050435f4c56440dfa1ea07d616399567c937bae5045e326b0ce8'
KIT=Path('/opt/paranoid-single-host/7f3a77154f6568d3bc34')
AUDIT=STATE/'reconciliations/rollback-8bbb341e'


def validate_restored(failed, previous, child, live):
    r.require(failed.get('phase')=='rolled-back' and failed.get('message_attempted') is True
              and failed.get('message_result') is None, 'not the known completed failed update')
    r.require(previous.get('phase')=='active' and failed.get('previous_transaction')==previous['transaction'], 'not an active predecessor')
    r.require(child.get('phase')=='rolled-back' and child.get('identity')==previous['message_result']['identity'], 'message rollback not confirmed')
    r.require(live==previous['message_result']['identity'], 'runtime differs from restored predecessor')
    return copy.deepcopy(previous)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--apply',action='store_true');p.add_argument('--expect-proof');args=p.parse_args()
    r.require(os.geteuid()==0,'fixed root-only operation')
    sys.dont_write_bytecode=True;sys.path.insert(0,str(KIT))
    import single_host as k
    k.trusted_directory(STATE,0,private=True);k.verify_root_kit(KIT);k.verify_kit(KIT)
    with k.exclusive_lock(STATE/'operator.lock'):
        fd=os.open(ROOT/'operation.lock',os.O_RDWR|os.O_NOFOLLOW|os.O_NONBLOCK)
        try:
            st=os.fstat(fd)
            r.require(stat.S_ISREG(st.st_mode) and st.st_uid==1003 and st.st_nlink==1 and st.st_mode&0o077==0,'unsafe operation lock')
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            current=STATE/'current.json';journal=STATE/'transactions'/FAILED/'journal.json'
            before=r.select_before(AUDIT,current,journal,FAILED_SHA)
            r.require(r.sha(before)==FAILED_SHA and r.read_checked(journal)==before,'failed record changed')
            previous_raw=r.read_checked(STATE/'transactions'/PREVIOUS/'journal.json')
            r.require(r.sha(previous_raw)==PREVIOUS_SHA,'predecessor changed')
            failed=k.decode_json(before);previous=k.decode_json(previous_raw)
            r.require(failed['transaction']==FAILED and previous['transaction']==PREVIOUS
                      and previous['kit_path']==str(KIT),'wrong transaction')
            child=k.decode_json(k.read_file(ROOT/'single-host-state'/FAILED/'journal.json',owner=1003,private=True))
            live=k.worker(previous['intent'],KIT,'status')['identity']
            validate_restored(failed,previous,child,live)
            intent=copy.deepcopy(previous['intent']);intent['expected']=live
            r.require(k.worker(intent,KIT,'preflight')['identity']==live,'original preflight')
            k.verify_system_artifacts(previous)
            network=k.network_module(KIT);spec=k.network_spec(previous['intent'])
            receipt=k.decode_json(k.read_file(STATE/'network-receipt.json',private=True))
            network.classify_ownership(spec,network.observe(spec),receipt)
            k.require_network_active(previous['intent'],KIT,k.coordinated_network(STATE,previous,'check'))
            r.require(k.require_message_ingress(previous['intent'],network.observe(spec))==previous['message_ingress_sha256'],'ingress changed')
            k.wait_relay_active(previous)
            r.require(k.worker(previous['intent'],KIT,'status')['identity']==live,'runtime changed during checks')
            proof=r.sha(r.canonical({'failed_sha256':FAILED_SHA,'active_sha256':PREVIOUS_SHA,
                                    'child_rollback_sha256':r.sha(k.canonical(child)),'identity':live}))
            r.require(r.read_checked(current) in (before,previous_raw),'current pointer changed')
            if args.apply:
                r.require(args.expect_proof==proof,'exact reviewed live proof required')
                r.directory(AUDIT.parent)
                if not os.path.lexists(AUDIT):AUDIT.mkdir(mode=0o700);r.sync_dir(AUDIT.parent)
                r.directory(AUDIT)
                r.immutable(AUDIT/'current.before',before)
                r.immutable(AUDIT/'current.after',previous_raw)
                r.immutable(AUDIT/'proof.sha256',(proof+'\n').encode())
                r.replace_exact(current,before,previous_raw)
                r.require(r.read_checked(journal)==before,'failed journal modified')
                r.require(r.read_checked(STATE/'transactions'/PREVIOUS/'journal.json')==previous_raw,'active journal modified')
                r.require(k.status(STATE)['verified'],'original status failed')
            print(json.dumps({'mode':'applied' if args.apply else 'read-only','proof_sha256':proof,
                              'failed_transaction_preserved':FAILED,'verified_active_predecessor':PREVIOUS,
                              'runtime_modified':False,'original_status_verified':bool(args.apply)}))
        finally:os.close(fd)

if __name__=='__main__':main()
