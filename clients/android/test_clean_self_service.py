#!/usr/bin/env python3
"""Clean-install actual JVM/JNI against the exact retained live bundle, locally.
Never contacts the compiled public default or any existing PostgreSQL instance.
"""
import argparse
import base64
import getpass
import hashlib
import shutil
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / 'clients/android'
PG = Path('/usr/lib/postgresql/16/bin')

def run(server_binary, evidence_dir, jni_library_dir=None):
    os.umask(0o077)
    server_binary = server_binary.resolve()
    server_digest = hashlib.sha256(server_binary.read_bytes()).hexdigest()
    assert server_digest == '3418332f112b2ce4ac699e9b5fb26222619b48dca7405fffdf69af237cf0c211', 'expected exact retained live bundle binary'
    evidence_dir.mkdir(parents=True, exist_ok=True)
    print('Retained server binary SHA256 '+server_digest, flush=True)
    if jni_library_dir is None:
        subprocess.run(['cargo','build','--offline','--locked','--manifest-path',str(ROOT/'clients/core/Cargo.toml')],check=True)
        jni_library_dir=ROOT/'clients/core/target/debug'
    jni_library_dir=jni_library_dir.resolve()
    jni_digest=hashlib.sha256((jni_library_dir/'libparanoid_client_core.so').read_bytes()).hexdigest()
    print('Actual JNI SHA256 '+jni_digest, flush=True)
    subprocess.run(['python3',str(ANDROID/'dependencies.py')],check=True)
    host=ANDROID/'out/host';host.mkdir(parents=True,exist_ok=True)
    cp=':'.join(str(p) for p in [host,ANDROID/'out/deps/json-20240303.jar',ANDROID/'out/deps/zxing-core-3.5.3.jar'])
    names=['CoreBridge','PinnedTls','SnapshotCodec','StorageGuard','SyncCycle','KeyClient','KeyTransport','SelfServiceClient','QrCodec']
    subprocess.run(['javac','--release','8','-Xlint:-options','-cp',cp,'-d',str(host)]+[str(ANDROID/f'src/org/paranoid/text/{n}.java') for n in names]+[str(ANDROID/'test/CleanSelfServiceBridge.java')],check=True)
    env={k:v for k,v in os.environ.items() if not k.startswith(('PG','PARANOID_'))}
    with tempfile.TemporaryDirectory(prefix='paranoid-client-v2-') as tmp:
        root=Path(tmp);sock=root/'socket';sock.mkdir(mode=0o700)
        pg=server=bridge=None
        log=(root/'fixture.log').open('w')
        try:
            subprocess.run([str(PG/'initdb'),'-D',str(root/'pg'),'--auth-local=trust','--auth-host=scram-sha-256','--no-locale','-E','UTF8'],check=True,env=env,stdout=log,stderr=log)
            pg=subprocess.Popen([str(PG/'postgres'),'-D',str(root/'pg'),'-k',str(sock),'-c','listen_addresses=','-c','unix_socket_permissions=0700','-c','log_statement=none','-c','log_min_error_statement=panic','-c','log_parameter_max_length_on_error=0'],env=env,stdout=log,stderr=log)
            for _ in range(100):
                if subprocess.run([str(PG/'pg_isready'),'-h',str(sock)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:break
                if pg.poll() is not None:raise AssertionError('own PostgreSQL exited')
                time.sleep(.05)
            else:raise AssertionError('own PostgreSQL not ready')
            ip=None
            for candidate in ['127.0.0.12','127.0.0.13','127.0.0.14']:
                try:
                    with socket.socket() as probe:probe.bind((candidate,38443))
                    ip=candidate;break
                except OSError:pass
            assert ip,'no free fixture address; never kill another process'
            subprocess.run(['python3',str(ROOT/'scripts/create-test-tls.py'),'--ip',ip,'--output',str(root/'tls')],check=True,stdout=log)
            public=json.loads((root/'tls/public-connection.json').read_text());realm=public['server_url'];pin=public['tls_spki_sha256']
            env.update(PARANOID_DATABASE_URL=f'postgresql://{getpass.getuser()}@localhost/postgres?host={sock}',PARANOID_KEY_REALM=realm,PARANOID_KEY_PIN=pin,PARANOID_MODE='self-service-v2-local',PARANOID_BIND=f'{ip}:38443',PARANOID_TLS_CERT=str(root/'tls/server.crt'),PARANOID_TLS_KEY=str(root/'tls/server.key'))
            binary=str(server_binary)
            subprocess.run([binary,'self-service-init'],env=env,check=True,stdout=log,stderr=log)
            opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=str(root/'tls/server.crt'))))
            def start_server():
                process=subprocess.Popen([binary],env=env,stdout=log,stderr=log)
                try:
                    for _ in range(100):
                        if process.poll() is not None:raise AssertionError('v2 local TLS server exited')
                        try:
                            with opener.open(realm+'/health',timeout=1) as response:
                                if response.status==200:return process
                        except OSError:time.sleep(.05)
                    raise AssertionError('v2 TLS server not ready')
                except BaseException:
                    if process.poll() is None:process.terminate();process.wait(timeout=10)
                    raise
            def start_bridge():
                return subprocess.Popen(['java','-Djava.library.path='+str(jni_library_dir),'-cp',cp,'CleanSelfServiceBridge',str(root/'phones'),realm,pin],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
            server=start_server();bridge=start_bridge()
            def rpc(phone,op,value='', expect_error=False):
                bridge.stdin.write(phone+'\t'+op+'\t'+base64.b64encode(value.encode()).decode()+'\n');bridge.stdin.flush()
                line=bridge.stdout.readline();assert line,'JNI bridge exited'
                result=json.loads(base64.b64decode(line))
                if expect_error:
                    assert 'error' in result, f'{phone}/{op}: expected rejection'
                else:
                    assert 'error' not in result,f'{phone}/{op}: {result.get("error")}: {result.get("detail")}'
                return result
            def stored_messages():
                result=subprocess.run([str(PG/'psql'),'-X','-h',str(sock),'-d','postgres','-At','-c',
                    "SELECT coalesce(json_agg(json_build_object('sender',sender,'recipient',recipient,'id',message_id,'ciphertext',replace(encode(ciphertext,'base64'),E'\\n','')) ORDER BY sequence),'[]'::json) FROM ss_messages"],
                    env=env,check=True,capture_output=True,text=True)
                return json.loads(result.stdout)
            def restart_bridge():
                nonlocal bridge
                bridge.stdin.close();assert bridge.wait(timeout=10)==0;bridge=start_bridge()
            def disk_hash(phone):
                return hashlib.sha256((root/'phones'/f'{phone}.enc').read_bytes()).hexdigest()
            def dialog(view, account):
                matches=[d for d in view['dialogs'] if d['account']==account]
                assert len(matches)==1, f'expected exactly one dialog with {account}; found {len(matches)}'
                return matches[0]
            def delivered(view, account, texts):
                d=dialog(view,account)
                assert [m['text'] for m in d['messages']]==texts, d['messages']
                assert all(m['delivered'] for m in d['messages']), d['messages']
                return d
            users={}
            for phone in ['one','two','three']:
                users[phone]=rpc(phone,'create');assert users[phone]['identity'] and not users[phone]['active']
                account=users[phone]['account'];users[phone]=rpc(phone,'sync')
                assert users[phone]['active'] and users[phone]['account']==account
                assert users[phone]['dialogs']==[]
            # Only the senders scan the recipient's genuine QR; recipient remains empty.
            for peer in ['two','three']:
                rpc(peer,'pair',json.dumps(users['one']['contact']))
            assert rpc('one','view')['dialogs']==[]
            queued={}
            for peer in ['two','three']:
                v=rpc(peer,'send',json.dumps({'account':users['one']['account'],'text':'Очередь '+peer}))
                assert not v['dialogs'][0]['messages'][0]['accepted']
                pending=rpc(peer,'pending')['pending'];assert len(pending)==1
                queued[peer]=pending[0]
                assert base64.b64decode(pending[0]['ciphertext'])[0]==2, 'all newly queued text must already be frame2 before network'
            # Pending exact signed bytes survive real encrypted persistence + process restart.
            restart_bridge()
            server.terminate();server.wait(timeout=10);server=start_server()
            for peer in queued:assert rpc(peer,'pending')['pending']==[queued[peer]]
            rpc('two','post_without_accept') # Server committed, caller lost response before local acceptance.
            stored=stored_messages();assert len(stored)==1
            assert stored[0]['id']==queued['two']['id'] and stored[0]['ciphertext']==queued['two']['ciphertext']
            restart_bridge()
            assert rpc('two','pending')['pending']==[queued['two']]
            for peer in ['two','three']:rpc(peer,'sync') # exact immutable retry is accepted by the actual server
            stored=stored_messages();assert len(stored)==2, 'lost-response retry duplicated server row'
            for peer in queued:
                match=[item for item in stored if item['id']==queued[peer]['id']]
                assert len(match)==1 and match[0]['ciphertext']==queued[peer]['ciphertext']
            # Failure saving a decrypted text/receipt candidate freezes the client; disk stays empty.
            one_before=disk_hash('one');rpc('one','fail_next_commit')
            rpc('one','sync',expect_error=True)
            assert disk_hash('one')==one_before, 'failed receipt commit changed retained snapshot'
            assert stored_messages()==stored, 'failed receipt save transmitted bytes'
            rpc('one','sync',expect_error=True)
            restart_bridge()
            assert rpc('one','view')['dialogs']==[], 'failed receive installed a peer'
            one=rpc('one','sync')
            assert len(one['dialogs'])==2, 'zero-contact recipient must show incoming plaintext immediately'
            for peer in ['two','three']:
                d=dialog(one,users[peer]['account'])
                assert [m['text'] for m in d['messages']]==['Очередь '+peer]
                assert d['trust']=='network_unverified' and not d['identity_verified'] and not d['blocked']
            # SyncCycle automatically flushes newly committed receipts after receive.
            receipts=[item for item in stored_messages() if item['sender']==users['one']['account']]
            assert len(receipts)==2
            assert rpc('one','pending')['pending']==[]
            assert all(base64.b64decode(item['ciphertext'])[0]==2 for item in receipts), 'receipts also require frame2'
            # Immediate unverified reply needs no approval or reciprocal scan.
            for peer in ['two','three']:
                rpc('one','send',json.dumps({'account':users[peer]['account'],'text':'Ответ '+peer}))
            rpc('one','sync')
            for peer in ['two','three']:rpc(peer,'sync')
            rpc('one','sync')
            for peer in ['two','three']:
                delivered(rpc(peer,'sync'),users['one']['account'],['Очередь '+peer,'Ответ '+peer])
                delivered(rpc('one','view'),users[peer]['account'],['Очередь '+peer,'Ответ '+peer])
            # Same-key QR only upgrades trust; exact history/channel survive reload.
            before=dialog(rpc('one','view'),users['two']['account'])
            after=dialog(rpc('one','pair',json.dumps(users['two']['contact'])),users['two']['account'])
            assert after['trust']=='out_of_band_verified' and after['identity_verified']
            assert before['channel']==after['channel'] and before['messages']==after['messages']
            # Block suppresses new plaintext and receipt; unrelated peer progresses normally.
            rpc('one','block',json.dumps({'account':users['two']['account'],'blocked':True}))
            blocked=dialog(rpc('one','view'),users['two']['account']);assert blocked['blocked']
            rpc('two','send',json.dumps({'account':users['one']['account'],'text':'Заблокированное'}));rpc('two','sync')
            rpc('three','send',json.dumps({'account':users['one']['account'],'text':'Дальше'}));rpc('three','sync')
            before_block_receive=[item for item in stored_messages() if item['sender']==users['one']['account']]
            one=rpc('one','sync')
            assert dialog(one,users['two']['account'])['messages']==blocked['messages']
            after_block_receive=[item for item in stored_messages() if item['sender']==users['one']['account']]
            assert len(after_block_receive)==len(before_block_receive)+1, 'only the unrelated peer gets a receipt'
            assert after_block_receive[-1]['recipient']==users['three']['account']
            rpc('one','sync');three=rpc('three','sync')
            assert dialog(three,users['one']['account'])['messages'][-1]['delivered']
            two=rpc('two','sync');assert not dialog(two,users['one']['account'])['messages'][-1]['delivered']
            rpc('one','block',json.dumps({'account':users['two']['account'],'blocked':False}))
            rpc('two','send',json.dumps({'account':users['one']['account'],'text':'После разблокировки'}));rpc('two','sync')
            one=rpc('one','sync')
            d=dialog(one,users['two']['account']);assert d['channel']==before['channel']
            assert d['messages'][-1]['text']=='После разблокировки'
            rpc('one','sync');two=rpc('two','sync')
            assert dialog(two,users['one']['account'])['messages'][-1]['delivered']
            # Two fresh peers both send before either receives: one deterministic channel.
            for phone in ['four','five']:
                rpc(phone,'create');users[phone]=rpc(phone,'sync')
            rpc('four','pair',json.dumps(users['five']['contact']));rpc('five','pair',json.dumps(users['four']['contact']))
            for phone,peer in [('four','five'),('five','four')]:
                rpc(phone,'send',json.dumps({'account':users[peer]['account'],'text':'Встречное '+phone}))
            for phone in ['four','five','four','five','four']:rpc(phone,'sync')
            four=dialog(rpc('four','view'),users['five']['account']);five=dialog(rpc('five','view'),users['four']['account'])
            assert four['channel']==five['channel']
            assert {m['text'] for m in four['messages']}=={'Встречное four','Встречное five'}
            assert {m['text'] for m in five['messages']}=={'Встречное four','Встречное five'}
            assert all(m['delivered'] for d in [four,five] for m in d['messages'])
            final={phone:rpc(phone,'view') for phone in users}
            restart_bridge()
            for phone in users:
                actual=rpc(phone,'sync')
                assert actual['account']==users[phone]['account']
                assert actual['dialogs']==final[phone]['dialogs'], 'restart/retry duplicated or changed history'
            assert hashlib.sha256(server_binary.read_bytes()).hexdigest()==server_digest
            summary={'result':'PASS','server_binary':str(server_binary),'server_sha256':server_digest,'jni_sha256':jni_digest,
                     'registration':'five fresh accounts, zero operator grants','receiver_initial_contacts':0,
                     'checks':['signed frame2 durable text and receipts verified against actual DB bytes','exact lost-response retry','receipt-save rollback/freeze',
                               'zero-contact plaintext/reply','genuine delivery receipts','same-key verification',
                               'block/unblock and unrelated peer progress','new/new crossing','encrypted snapshot/server/JVM restart'],
                     'boundary':'generated loopback pinnedTLS + isolated PostgreSQL only; no phones or live actions'}
            (evidence_dir/'clean-fixture-result.json').write_text(json.dumps(summary,indent=2)+'\n')
            print('PASS exact retained live v2 binary + generated pinnedTLS/private PostgreSQL + actual Android JVM/JNI: '+', '.join(summary['checks']),flush=True)
        finally:
            if bridge is not None:
                bridge.stdin.close();bridge.wait(timeout=10)
            if server is not None and server.poll() is None:server.terminate();server.wait(timeout=10)
            if pg is not None and pg.poll() is None:pg.send_signal(signal.SIGINT);pg.wait(timeout=20)
            log.close()
            shutil.copyfile(root/'fixture.log',evidence_dir/'clean-fixture-server.log')

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--server-binary',type=Path,required=True)
    parser.add_argument('--evidence-dir',type=Path,required=True)
    parser.add_argument('--jni-library-dir',type=Path,help='Use and hash an already-built JNI library; omitted builds current core')
    args=parser.parse_args()
    run(args.server_binary,args.evidence_dir,args.jni_library_dir)
