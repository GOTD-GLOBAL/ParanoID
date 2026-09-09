#!/usr/bin/env python3
"""Public deterministic conformance vectors; never uses application credentials.

Independent encoder/signature implementation via Python cryptography/OpenSSL.
The two deterministic RFC-style fixture seeds are public test inputs, not usable
application identities. Output contains PUBLIC material only.
"""
import base64
import hashlib
import json
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

def lp(fields):return b''.join(len(s.encode()).to_bytes(4,'big')+s.encode() for s in fields)
def digest(b):return hashlib.sha256(b).hexdigest()
def b64(b):return base64.b64encode(b).decode().rstrip('=')
def pub(k):return b64(k.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw))
def main():
    root=Ed25519PrivateKey.from_private_bytes(bytes(range(32)))
    device=Ed25519PrivateKey.from_private_bytes(bytes(range(32,64)))
    c={'root':pub(root),'account':digest(lp(['paranoid-account-v1',pub(root)])),
       'device':'00000000-0000-4000-8000-000000000001','auth':pub(device),
       'realm':'https://127.0.0.2:38443','pin':'a'*64,
       'olm':digest(lp(['paranoid-olm-v1',b64(bytes(range(64,96))),b64(bytes(range(96,128)))]))}
    cb=lp(['paranoid-credential-v1']+[c[k] for k in ['root','account','device','auth','realm','pin','olm']])
    c['signature']=b64(root.sign(cb));fingerprint=digest(cb)
    p={'id':'00000000-0000-4000-8000-000000000002','nonce':base64.b64encode(bytes(range(32))).decode(),
       'epoch':'00000000-0000-4000-8000-000000000003','expires':2000000000,
       'realm':c['realm'],'pin':c['pin'],'account':c['account'],'device':c['device'],'credential':fingerprint,
       'grant':'00000000-0000-4000-8000-000000000004','slot':0,'purpose':'enroll','method':'POST',
       'path':'/v1/enrollment/commit','body':digest(b'{}')}
    pb=lp(['paranoid-proof-v1']+[str(p[k]) for k in ['id','nonce','epoch','expires','realm','pin','account','device','credential','grant','slot','purpose','method','path','body']])
    result={'credential':c,'credential_bytes_hex':cb.hex(),'credential_fingerprint':fingerprint,'proof':p,'proof_bytes_hex':pb.hex(),'proof_signature':b64(device.sign(pb))}
    path=Path(__file__).resolve().parents[1]/'docs/protocol/key-enrollment-v1-vectors.json'
    path.write_text(json.dumps(result,indent=2)+'\n')
    print('Public conformance vectors written; no operational keys accessed')
if __name__=='__main__':main()
