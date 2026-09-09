#!/usr/bin/env python3
"""REG-01..06: isolated native TLS/PG and the Android Java/JNI workflow. No live endpoint."""
import base64
import getpass
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

ROOT = Path(__file__).resolve().parents[1]
PG = Path('/usr/lib/postgresql/16/bin')
EVIDENCE = Path(os.environ.get('PARANOID_EVIDENCE', '/home/codex/paranoid-registration-evidence'))

def run():
    os.umask(0o077)
    legacy=os.environ.get('PARANOID_LEGACY_FIXTURE')=='1'
    EVIDENCE.mkdir(mode=0o700, exist_ok=True)
    subprocess.run(['cargo','build','--locked','--manifest-path','server/Cargo.toml'],cwd=ROOT,check=True)
    subprocess.run(['cargo','build','--locked','--manifest-path','clients/core/Cargo.toml'],cwd=ROOT,check=True)
    env={k:v for k,v in os.environ.items() if not k.startswith(('PG','PARANOID_'))}
    with tempfile.TemporaryDirectory(prefix='paranoid-registration-') as temp:
        root=Path(temp); root.chmod(0o700); sock=root/'socket';sock.mkdir(mode=0o700)
        pg=None;server=None;bridge=None
        logs=[]
        def log(name):
            f=(EVIDENCE/name).open('a');logs.append(f);return f
        try:
            subprocess.run([str(PG/'initdb'),'-D',str(root/'data'),'--auth-local=trust','--auth-host=scram-sha-256','--no-locale','-E','UTF8'],env=env,check=True,stdout=log('registration-postgres-init.log'),stderr=subprocess.STDOUT)
            pg=subprocess.Popen([str(PG/'postgres'),'-D',str(root/'data'),'-k',str(sock),'-c','listen_addresses=','-c','unix_socket_permissions=0700','-c','log_statement=none','-c','log_min_error_statement=panic','-c','log_parameter_max_length_on_error=0'],env=env,stdout=log('registration-postgres.log'),stderr=subprocess.STDOUT)
            for _ in range(100):
                r=subprocess.run([str(PG/'pg_isready'),'-h',str(sock)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                if r.returncode==0:break
                if pg.poll() is not None:raise AssertionError('own PostgreSQL exited')
                time.sleep(.05)
            else:raise AssertionError('own PostgreSQL not ready')
            ip=None
            for candidate in ['127.0.0.2','127.0.0.3','127.0.0.4']:
                try:
                    with socket.socket() as p:p.bind((candidate,38443))
                    ip=candidate;break
                except OSError:pass
            assert ip,'no isolated loopback address available; no process killed'
            subprocess.run(['python3',str(ROOT/'scripts/create-test-tls.py'),'--ip',ip,'--output',str(root/'tls')],check=True,stdout=log('registration-public-tls.log'))
            pub=json.loads((root/'tls/public-connection.json').read_text())
            url=pub['server_url'];pin=pub['tls_spki_sha256']
            env.update(PARANOID_DATABASE_URL=f'postgresql://{getpass.getuser()}@localhost/postgres?host={sock}',PARANOID_KEY_REALM=url,PARANOID_KEY_PIN=pin,
                PARANOID_MODE='closed-alpha-key-v1',PARANOID_BIND=f'{ip}:38443',PARANOID_TLS_CERT=str(root/'tls/server.crt'),PARANOID_TLS_KEY=str(root/'tls/server.key'),
                PARANOID_ALICE_TOKEN='a'*64,PARANOID_BOB_TOKEN='b'*64)
            binary=str(ROOT/'server/target/debug/paranoid-server')
            sources=['CoreBridge','PinnedTls','SnapshotCodec','SyncCycle','KeyClient','KeyTransport','QrCodec']
            classpath=str(ROOT/'clients/android/out/host')+':'+str(ROOT/'clients/android/out/deps/json-20240303.jar')+':'+str(ROOT/'clients/android/out/deps/zxing-core-3.5.3.jar')
            subprocess.run(['javac','--release','8','-Xlint:-options','-cp',classpath,'-d',str(ROOT/'clients/android/out/host')]+[str(ROOT/f'clients/android/src/org/paranoid/text/{s}.java') for s in sources]+[str(ROOT/'clients/android/test/RegistrationBridge.java'),str(ROOT/'clients/android/test/LegacyMigrationSmoke.java'),str(ROOT/'clients/android/test/PublicQr.java')],check=True)
            def sql(text,database='postgres'):
                return subprocess.check_output([str(PG/'psql'),'-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h',str(sock),'-U',getpass.getuser(),'-d',database],input=text.encode(),env=env)
            if legacy:
                subprocess.run(['java','-Djava.library.path='+str(ROOT/'clients/core/target/debug'),'-cp',classpath,'LegacyMigrationSmoke',str(root/'phones'),url,pin],check=True)
                sql((ROOT/'server/schema.sql').read_text())
                envelope=json.loads((root/'phones/legacy-envelope.json').read_text());import uuid
                identifier=str(uuid.UUID(envelope['id']));frame=base64.b64decode(envelope['ciphertext'],validate=True)
                sql(f"INSERT INTO envelopes VALUES(1,0,1,'{identifier}',decode('{frame.hex()}','hex')); UPDATE room_state SET sequence=1,used_bytes={len(frame)};")
                original=sql('SELECT row_to_json(e) FROM envelopes e ORDER BY sequence; SELECT row_to_json(r) FROM room_state r;')
            subprocess.run([binary,'key-admin-init'],env=env,check=True)
            if legacy:assert original==sql('SELECT row_to_json(e) FROM envelopes e ORDER BY sequence; SELECT row_to_json(r) FROM room_state r;'),'migration changed original committed rows'
            context=ssl.create_default_context(cafile=str(root/'tls/server.crt'))
            opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=context))
            def start():
                p=subprocess.Popen([binary],env=env,stdout=log('registration-server.log'),stderr=subprocess.STDOUT)
                try:
                    for _ in range(100):
                        if p.poll() is not None:raise AssertionError('key-only local TLS server must start')
                        try:
                            with opener.open(url+'/health',timeout=1) as r:
                                if r.status==200:return p
                        except OSError:time.sleep(.05)
                    raise AssertionError('own key TLS server not ready')
                except BaseException:
                    if p.poll() is None:p.terminate();p.wait(timeout=10)
                    raise
            server=start()
            print('PASS: isolated native key server starts with TLS and private PostgreSQL',flush=True)
            pending=[]
            try:
                for _ in range(16):pending.append(socket.create_connection((ip,38443),timeout=2))
                extra=socket.create_connection((ip,38443),timeout=2);pending.append(extra);extra.settimeout(2)
                try:closed=extra.recv(1)==b''
                except ConnectionResetError:closed=True
                except socket.timeout:closed=False
                assert closed,'seventeenth unnegotiated TLS connection must be refused before handshake'
            finally:
                for connection in pending:connection.close()
            print('PASS: concurrent TLS handshake/connection ceiling rejects excess without unbounded tasks',flush=True)
            def bridge_start():
                return subprocess.Popen(['java','-Djava.library.path='+str(ROOT/'clients/core/target/debug'),'-cp',classpath,'RegistrationBridge',str(root/'phones'),url,pin],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
            bridge=bridge_start()
            def rpc(phone,op,value=''):
                bridge.stdin.write(phone+'\t'+op+'\t'+base64.b64encode(value.encode()).decode()+'\n');bridge.stdin.flush()
                line=bridge.stdout.readline();assert line,'JVM bridge exited'
                result=json.loads(base64.b64decode(line));assert 'error' not in result, 'phone workflow rejected '+op+': '+str(result.get('error',''))
                return result
            for slot,phone in enumerate(['one','two']):
                view=rpc(phone,'create');assert view['identity'] and not view['active']
                request=view['request'];c=request['credential']
                fields=['paranoid-credential-v1']+[c[k] for k in ['root','account','device','auth','realm','pin','olm']]
                import hashlib
                fingerprint=hashlib.sha256(b''.join(len(f.encode()).to_bytes(4,'big')+f.encode() for f in fields)).hexdigest()
                request_file=root/(phone+'-request.json');request_file.write_text(json.dumps(request))
                grant_file=root/(phone+'-grant.json')
                subprocess.run([binary,'key-admin-approve',str(slot),fingerprint,c['olm'],str(request_file),str(grant_file)],env=env,check=True)
                subprocess.run(['java','-cp',classpath,'PublicQr',str(grant_file),str(root/(phone+'-grant.png'))],check=True)
                view=rpc(phone,'grant',grant_file.read_text());assert view['active']
            a=rpc('one','view');b=rpc('two','view')
            rpc('one','pair',json.dumps(b['contact']));rpc('two','pair',json.dumps(a['contact']))
            a=rpc('one','send','Тест A → B');sent=next(m for m in a['messages'] if m['text']=='Тест A → B');assert sent['accepted'] and not sent['delivered']
            bridge.stdin.close();bridge.wait(timeout=10);bridge=None
            server.terminate();server.wait(timeout=10);server=None
            server=start();bridge=bridge_start()
            rpc('two','sync');rpc('two','sync');a=rpc('one','sync');assert next(m for m in a['messages'] if m['text']=='Тест A → B')['delivered']
            rpc('two','send','Тест B → A')
            for p in ['one','one','two','one','two']:rpc(p,'sync')
            for p in ['one','two']:
                v=rpc(p,'view');assert len(v['messages'])==(3 if legacy else 2) and v['active']
                assert {m['text'] for m in v['messages']}==({'Тест A → B','Тест B → A','До миграции'} if legacy else {'Тест A → B','Тест B → A'})
            for token in ['a'*64,'b'*64]:
                try:opener.open(urllib.request.Request(url+'/v0/messages',headers={'Authorization':'Bearer '+token}),timeout=5);raise AssertionError('v0 bearer revived')
                except urllib.error.HTTPError as e:assert e.code==401
            print('PASS: actual Android KeyClient + JNI vodozemac, two explicit operator grants, automatic key login/activation, pinned TLS/PG, bidirectional Cyrillic E2EE/receipts, server/JVM restart, encrypted snapshots and no duplicate display. NOT a phone test.',flush=True)
            dump=root/'history.dump'
            subprocess.run([str(PG/'pg_dump'),'-h',str(sock),'-U',getpass.getuser(),'-d','postgres','-Fc','-f',str(dump)],env=env,check=True)
            sql('CREATE DATABASE restored;')
            subprocess.run([str(PG/'pg_restore'),'-h',str(sock),'-U',getpass.getuser(),'-d','restored','--exit-on-error',str(dump)],env=env,check=True)
            for table,order in [('envelopes','sequence'),('room_state','id'),('key_meta','id'),('key_grants','slot')]:
                query=f'SELECT row_to_json(t) FROM {table} t ORDER BY {order};'
                assert sql(query)==sql(query,'restored'),'restored rows differ'
            stale=env.copy();stale['PARANOID_MODE']='closed-alpha-v0';stale['PARANOID_DATABASE_URL']=env['PARANOID_DATABASE_URL'].replace('/postgres?','/restored?')
            server.terminate();server.wait(timeout=10);server=None
            refused=subprocess.run([binary],env=stale,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)
            assert refused.returncode!=0,'v0 startup on restored migrated DB must fail'
            env['PARANOID_DATABASE_URL']=stale['PARANOID_DATABASE_URL'];server=start()
            for phone in ['one','two']:rpc(phone,'sync')
            print('PASS: populated dump/restore exactly preserves envelopes/room/grants/modes and refuses v0 startup; legacy migration fixture='+str(legacy),flush=True)
        finally:
            if bridge is not None:
                bridge.stdin.close();bridge.wait(timeout=10)
            if server is not None and server.poll() is None:server.terminate();server.wait(timeout=10)
            if pg is not None and pg.poll() is None:pg.send_signal(signal.SIGINT);pg.wait(timeout=20)
            for f in logs:f.close()
if __name__=='__main__':run()
