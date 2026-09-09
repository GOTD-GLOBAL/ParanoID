"""Fetch exact public Maven artifacts and verify pinned SHA256 before compilation."""
import hashlib
from pathlib import Path
import urllib.request

DEPS = {
    'zxing-core-3.5.3.jar': ('com/google/zxing/core/3.5.3/core-3.5.3.jar', '8d8064c1636fdaef7189dd9055c7d59950a8940a12f2293956446ec3c109fd82'),
    # JVM fixture only; Android supplies org.json. Never passed to d8.
    'json-20240303.jar': ('org/json/json/20240303/json-20240303.jar', '3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed'),
}
def main():
    dest=Path(__file__).resolve().parent/'out/deps';dest.mkdir(parents=True,exist_ok=True)
    for name,(path,expected) in DEPS.items():
        target=dest/name
        if target.exists():data=target.read_bytes()
        else:
            with urllib.request.urlopen('https://repo.maven.apache.org/maven2/'+path,timeout=30) as response:data=response.read(2*1024*1024+1)
        if len(data)>2*1024*1024 or hashlib.sha256(data).hexdigest()!=expected:raise RuntimeError('dependency integrity check failed: '+name)
        if not target.exists():target.write_bytes(data)
        print('Verified SHA256: '+name)
if __name__=='__main__':main()
