#!/usr/bin/env python3
"""Create one self-signed IP TLS identity; never deploy or overwrite an identity.

Run on the intended server under its application account after authorization.
Only the public connection descriptor is printed. Keep the private key local.
"""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import subprocess

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--ip",required=True)
parser.add_argument("--port",type=int,default=38443)
parser.add_argument("--output",type=Path,required=True)
args=parser.parse_args()
ip=ipaddress.ip_address(args.ip)
if not 1024<=args.port<=65535:parser.error("use an explicitly selected unprivileged test TLS port")
output=args.output.absolute()
parent=output.parent.stat()
if parent.st_uid!=os.geteuid() or parent.st_mode & 0o022:parser.error("output parent must be owned by this user and not writable by others")
old_mask=os.umask(0o077)
try:
    output.mkdir(mode=0o700,exist_ok=False) # Refuse key replacement/accidental repinning.
    key=output/"server.key";cert=output/"server.crt"
    subprocess.run(["openssl","req","-x509","-newkey","ec","-pkeyopt","ec_paramgen_curve:prime256v1",
                    "-nodes","-sha256","-days","90","-subj","/CN=ParanoID closed test",
                    "-addext",f"subjectAltName=IP:{ip}","-addext","basicConstraints=critical,CA:FALSE",
                    "-addext","keyUsage=critical,digitalSignature","-addext","extendedKeyUsage=serverAuth",
                    "-keyout",str(key),"-out",str(cert)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    key.chmod(0o600)
    public=subprocess.check_output(["openssl","x509","-in",str(cert),"-pubkey","-noout"])
    spki=subprocess.check_output(["openssl","pkey","-pubin","-outform","DER"],input=public)
    host=f"[{ip}]" if ip.version==6 else str(ip)
    descriptor={"server_url":f"https://{host}:{args.port}","tls_spki_sha256":hashlib.sha256(spki).hexdigest()}
    (output/"public-connection.json").write_text(json.dumps(descriptor,indent=2)+"\n")
    print(json.dumps(descriptor))
finally:
    os.umask(old_mask)
