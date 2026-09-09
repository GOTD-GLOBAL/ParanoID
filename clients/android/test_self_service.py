#!/usr/bin/env python3
"""Actual JVM/JNI v2 interoperability against a separate local server checkout.
Never contacts the compiled public default or any existing PostgreSQL instance.
"""
import argparse
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

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / 'clients/android'
PG = Path('/usr/lib/postgresql/16/bin')

def run(server_root):
    os.umask(0o077)
    server_root = server_root.resolve()
    subprocess.run(['cargo','build','--locked','--manifest-path',str(server_root/'server/Cargo.toml')],check=True)
    subprocess.run(['cargo','build','--locked','--manifest-path',str(ROOT/'clients/core/Cargo.toml')],check=True)
    subprocess.run(['python3',str(ANDROID/'dependencies.py')],check=True)
    host=ANDROID/'out/host';host.mkdir(parents=True,exist_ok=True)
    cp=':'.join(str(p) for p in [host,ANDROID/'out/deps/json-20240303.jar',ANDROID/'out/deps/zxing-core-3.5.3.jar'])
    names=['CoreBridge','PinnedTls','SnapshotCodec','StorageGuard','SyncCycle','KeyClient','KeyTransport','SelfServiceClient','QrCodec']
    subprocess.run(['javac','--release','8','-Xlint:-options','-cp',cp,'-d',str(host)]+[str(ANDROID/f'src/org/paranoid/text/{n}.java') for n in names]+[str(ANDROID/'test/SelfServiceBridge.java')],check=True)
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
            binary=str(server_root/'server/target/debug/paranoid-server')
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
                return subprocess.Popen(['java','-Djava.library.path='+str(ROOT/'clients/core/target/debug'),'-cp',cp,'SelfServiceBridge',str(root/'phones'),realm,pin],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
            server=start_server();bridge=start_bridge()
            def rpc(phone,op,value=''):
                bridge.stdin.write(phone+'\t'+op+'\t'+base64.b64encode(value.encode()).decode()+'\n');bridge.stdin.flush()
                line=bridge.stdout.readline();assert line,'JNI bridge exited'
                result=json.loads(base64.b64decode(line));assert 'error' not in result,f'{phone}/{op}: {result.get("error")}'
                return result
            users={}
            for phone in ['one','two','three']:
                users[phone]=rpc(phone,'create');assert users[phone]['identity'] and not users[phone]['active']
                account=users[phone]['account'];users[phone]=rpc(phone,'sync')
                assert users[phone]['active'] and users[phone]['account']==account
            for peer in ['two','three']:
                rpc('one','pair',json.dumps(users[peer]['contact']));rpc(peer,'pair',json.dumps(users['one']['contact']))
            # Queue offline, then restart both real server and JVM before network use.
            for peer in ['two','three']:
                v=rpc(peer,'send',json.dumps({'account':users['one']['account'],'text':'Очередь '+peer}))
                assert not v['dialogs'][0]['messages'][0]['accepted']
            bridge.stdin.close();bridge.wait(timeout=10);bridge=None
            server.terminate();server.wait(timeout=10);server=None
            server=start_server();bridge=start_bridge()
            for peer in ['two','three']:rpc(peer,'sync')
            rpc('one','sync')
            for peer in ['two','three']:
                v=rpc(peer,'sync');assert v['dialogs'][0]['messages'][0]['delivered']
                rpc('one','send',json.dumps({'account':users[peer]['account'],'text':'Ответ '+peer}))
            rpc('one','sync')
            for peer in ['two','three']:rpc(peer,'sync')
            rpc('one','sync');one=rpc('one','sync')
            assert len(one['dialogs'])==2
            for d in one['dialogs']:
                assert len(d['messages'])==2
                assert all(m['delivered'] for m in d['messages'])
            for phone in users:assert rpc(phone,'view')['account']==users[phone]['account']
            print('PASS actual v2 pinned TLS/PostgreSQL + Android JVM/JNI: 3 self-registered users, verified QR, 2 independent dialogs, E2EE text/receipts, offline queue, encrypted snapshot/JVM/server restart, stable IDs and no duplicate history. NOT a physical-phone or hosted test.')
        finally:
            if bridge is not None:
                bridge.stdin.close();bridge.wait(timeout=10)
            if server is not None and server.poll() is None:server.terminate();server.wait(timeout=10)
            if pg is not None and pg.poll() is None:pg.send_signal(signal.SIGINT);pg.wait(timeout=20)
            log.close()

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--server-root',type=Path,required=True)
    run(parser.parse_args().server_root)
