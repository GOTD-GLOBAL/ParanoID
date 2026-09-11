#!/usr/bin/env python3
"""Real local pinned TLS -> production Java parser/download + pure provider policy.
No hosted requests. Disposable TLS keys are not Android signing keys.
"""
from pathlib import Path
import datetime, hashlib, http.server, ipaddress, json, os, ssl, subprocess, tempfile, threading
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
ROOT=Path(__file__).resolve().parent
CP=os.pathsep.join(str(ROOT/p) for p in ['out/update-host','out/host','out/deps/json-20240303.jar'])
def run(*args, success=True):
    p=subprocess.run(['java','-Dhttps.proxyHost=127.0.0.23','-Dhttps.proxyPort=1','-Djava.library.path='+str(ROOT.parent/'core/target/debug'),'-cp',CP,*args],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=25)
    if (p.returncode==0)!=success: raise AssertionError(p.stdout)
    return p.stdout

def main():
    sources=[ROOT/'src/org/paranoid/text'/f'{n}.java' for n in ['UpdateManifest','UpdatePolicy','UpdateClient','PinnedTls','KeyClient','CoreBridge','KeyTransport','SyncCycle','SelfServiceClient']]
    sources += list((ROOT/'test').glob('Update*Smoke.java'))
    (ROOT/'out/update-host').mkdir(exist_ok=True,parents=True)
    subprocess.run(['javac','--release','8','-Xlint:-options','-cp',str(ROOT/'out/deps/json-20240303.jar'),'-d',str(ROOT/'out/update-host'),*map(str,sources)],check=True)
    print(run('org.paranoid.text.UpdateSmoke').strip());print(run('org.paranoid.text.UpdatePolicySmoke').strip());print(run('org.paranoid.text.UpdateTrustSmoke').strip())
    # Actual retained signed v5 fixture (or an explicitly supplied APK), not invented APK bytes.
    apk=Path(os.environ.get('PARANOID_UPDATE_FIXTURE',str(ROOT/'out/paranoid-text.apk'))).read_bytes()
    digest=hashlib.sha256(apk).hexdigest()
    metadata=dict(schema=1,package='global.paranoid.messenger',version_code=6,version_name='0.0.6-update',min_sdk=26,abi='arm64-v8a',apk_sha256=digest,apk_size=len(apk))
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,*args):pass
        def do_GET(self):
            assert not self.headers.get('Authorization') and not self.headers.get('Cookie')
            self.server.paths.append(self.path)
            mode=self.server.mode; status=200; body=json.dumps(metadata).encode(); chunked=False
            if self.path=='/v2/updates/android':
                if mode=='absent':status=404;body=b''
                elif mode=='redirect':status=302;body=b''
                elif mode=='metadata-big':body=b' '*8193
                elif mode=='metadata-invalid':body=b'{"schema":1,"schema":1}'
                elif mode=='metadata-utf8':body=b'\xc3('
                elif mode=='bad-hash':body=json.dumps(dict(metadata,apk_sha256='b'*64)).encode()
                elif mode=='size-small':body=json.dumps(dict(metadata,apk_size=len(apk)-1)).encode()
                elif mode=='size-large':body=json.dumps(dict(metadata,apk_size=len(apk)+1)).encode()
            elif self.path in ('/v2/updates/android/apk/'+digest,'/v2/updates/android/apk/'+'b'*64):
                body=apk
                if mode=='truncated':body=apk[:-1]
                if mode=='overflow':body=apk+b'x';chunked=True
                if mode=='chunked':chunked=True
                if mode=='apk-redirect':status=307;body=b''
            else:status=404;body=b''
            self.send_response(status)
            if status in (302,307):self.send_header('Location','https://127.0.0.23:1/never')
            if mode=='encoding':self.send_header('Content-Encoding','gzip')
            if chunked:self.send_header('Transfer-Encoding','chunked')
            else:self.send_header('Content-Length',str(len(apk) if mode=='truncated' and '/apk/' in self.path else len(body)))
            self.send_header('Connection','close');self.end_headers()
            try:
                if chunked:self.wfile.write(f'{len(body):x}\r\n'.encode()+body+b'\r\n0\r\n\r\n')
                else:self.wfile.write(body)
            except (BrokenPipeError,ConnectionResetError,ssl.SSLError):pass
            self.close_connection=True
    with tempfile.TemporaryDirectory(prefix='paranoid-update-tls-') as tmp:
        tmp=Path(tmp);key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        keyfile=tmp/'tls.key';keyfile.write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()));keyfile.chmod(0o600)
        pin=hashlib.sha256(key.public_key().public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo)).hexdigest()
        def cert(kind):
            now=datetime.datetime.now(datetime.timezone.utc);name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'Disposable update fixture')])
            b=x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(days=2)).not_valid_after(now+datetime.timedelta(days=1) if kind!='expired' else now-datetime.timedelta(days=1))
            b=b.add_extension(x509.BasicConstraints(ca=kind=='ca',path_length=None),True).add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.24' if kind=='san' else '127.0.0.23'))]),False).add_extension(x509.KeyUsage(True,False,True,False,False,False,False,False,False),True).add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),False)
            p=tmp/'tls.pem';p.write_bytes(b.sign(key,hashes.SHA256()).public_bytes(serialization.Encoding.PEM));return p
        for kind in ['valid','expired','san','ca']:
            ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(cert(kind),keyfile)
            server=http.server.ThreadingHTTPServer(('127.0.0.23',0),Handler);server.socket=ctx.wrap_socket(server.socket,server_side=True);server.paths=[]
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();realm=f'https://127.0.0.23:{server.server_port}'
            try:
                if kind=='valid':
                    for invalid in [realm.replace('https:','http:'),realm+'/',realm+'?file=x',realm+'#x',realm.replace('https://','https://user:secret@')]:
                        run('org.paranoid.text.UpdateNetworkSmoke',invalid,pin,'ok',success=False)
                    print('Non-origin/cleartext/credential URLs: REJECT PASS; explicit unusable JVM proxy ignored')
                modes=['ok','chunked','absent','redirect','apk-redirect','metadata-big','metadata-invalid','metadata-utf8','bad-hash','size-small','size-large','truncated','overflow','encoding','reject-apk','wrong-pin','cookie'] if kind=='valid' else ['ok']
                for mode in modes:
                    server.mode=mode;server.paths.clear();success=kind=='valid' and mode in ['ok','chunked','absent']
                    out=run('org.paranoid.text.UpdateNetworkSmoke',realm,'0'*64 if mode=='wrong-pin' else pin,mode,success=success)
                    assert all(p=='/v2/updates/android' or p.startswith('/v2/updates/android/apk/') for p in server.paths)
                    if mode=='redirect':assert server.paths==['/v2/updates/android']
                    if not success and 'AssertionError' in out:raise AssertionError(out)
                    print(f'TLS {kind}/{mode}: '+('PASS' if success else 'REJECT PASS'))
            finally:server.shutdown();server.server_close();thread.join()
    print('RFC0013 host fixture PASS (not Android PackageManager/installer/device evidence)')
if __name__=='__main__':main()
