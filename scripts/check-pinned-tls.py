#!/usr/bin/env python3
"""Temporary self-signed TLS fixtures and real loopback JVM handshakes; no deploy."""
from pathlib import Path
import os
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
def execute(args):
    subprocess.run(args,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
with tempfile.TemporaryDirectory(prefix="paranoid-tls-test-") as temp:
    root=Path(temp);root.chmod(0o700)
    previous=os.umask(0o077)
    try:
        key=root/"key.pem"
        for name,ip in [("valid","127.0.0.1"),("wrong-ip","127.0.0.2")]:
            cmd=["openssl","req","-x509","-sha256","-days","1","-subj","/CN=ParanoID TLS fixture","-addext","subjectAltName=IP:"+ip,"-addext","basicConstraints=critical,CA:FALSE","-addext","keyUsage=critical,digitalSignature","-addext","extendedKeyUsage=serverAuth","-out",str(root/(name+".crt"))]
            if name=="valid":cmd += ["-newkey","ec","-pkeyopt","ec_paramgen_curve:prime256v1","-nodes","-keyout",str(key)]
            else:cmd += ["-key",str(key)]
            execute(cmd)
        execute(["openssl","x509","-in",str(root/"valid.crt"),"-signkey",str(key),"-days","-1","-out",str(root/"expired.crt")])
        for name in ["valid","wrong-ip","expired"]:
            execute(["openssl","pkcs12","-export","-inkey",str(key),"-in",str(root/(name+".crt")),"-name","tls","-passout","pass:test-only","-out",str(root/(name+".p12"))])
        execute(["javac","-d",str(root),str(ROOT/"clients/android/src/org/paranoid/text/PinnedTls.java"),str(ROOT/"clients/android/test/TlsSmoke.java")])
        subprocess.run(["java","-cp",str(root),"TlsSmoke",str(root/"valid.p12"),str(root/"wrong-ip.p12"),str(root/"expired.p12")],check=True)
    finally:os.umask(previous)
