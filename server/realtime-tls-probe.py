#!/usr/bin/env python3
"""Actual generated-pinnedTLS session pooling/lifetime probe; synthetic identity only."""
import argparse
import base64
import hashlib
import http.client
import json
import ssl
import time
import uuid

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def lp(fields):
    return b"".join(len(str(v).encode()).to_bytes(4, "big") + str(v).encode() for v in fields)


def b64(raw):
    return base64.b64encode(raw).decode().rstrip("=")


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--certificate", required=True)
    parser.add_argument("--pin", required=True)
    args = parser.parse_args()
    realm = f"https://127.0.0.1:{args.port}"
    context = ssl.create_default_context(cafile=args.certificate)
    context.set_alpn_protocols(["http/1.1"])

    def connect():
        conn = http.client.HTTPSConnection("127.0.0.1", args.port, timeout=28, context=context)
        conn.connect()
        cert = x509.load_der_x509_certificate(conn.sock.getpeercert(binary_form=True))
        pin = hashlib.sha256(cert.public_key().public_bytes(
            serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)).hexdigest()
        assert pin == args.pin, "strict generated fixture SPKI mismatch"
        return conn

    connection = connect()
    original_socket = connection.sock
    opened = time.monotonic()

    def request(method, path, body=b"", auth=None):
        headers = {"Content-Type": "application/json"}
        if auth:
            headers["Authorization"] = auth
        connection.request(method, path, body, headers)
        response = connection.getresponse()
        raw = response.read()
        return response.status, json.loads(raw)

    assert request("GET", "/health")[0] == 200
    assert connection.sock is original_socket, "server closed first TLS response; pooling missing"
    assert request("GET", "/health")[0] == 200
    assert connection.sock is original_socket, "two requests must reuse one actual TLS socket"

    root, auth = Ed25519PrivateKey.generate(), Ed25519PrivateKey.generate()
    def public(key):
        return b64(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))
    credential = {"root": public(root), "account": hashlib.sha256(lp(["paranoid-account-v1", public(root)])).hexdigest(),
                  "device": str(uuid.uuid4()), "auth": public(auth), "realm": realm, "pin": args.pin, "olm": "a" * 64}
    credential_bytes = lp(["paranoid-credential-v1"] + [credential[n] for n in ("root", "account", "device", "auth", "realm", "pin", "olm")])
    credential["signature"] = b64(root.sign(credential_bytes))
    fingerprint = hashlib.sha256(credential_bytes).hexdigest()

    def old_signed(purpose, path):
        time.sleep(.56)
        register = purpose == "register"
        payload = {"credential": credential if register else fingerprint, "purpose": purpose,
                   "method": "POST", "path": path, "body": hashlib.sha256(b"{}").hexdigest()}
        if not register:
            payload.update(account=credential["account"], device=credential["device"])
        code, ch = request("POST", "/v2/" + ("registration" if register else "auth") + "/challenge", json.dumps(payload).encode())
        assert code == 200, f"fixture challenge rejected: {code}"
        fields = ("id", "nonce", "epoch", "expires", "realm", "pin", "account", "device", "credential", "purpose", "method", "path", "body")
        signature = b64(auth.sign(lp(["paranoid-proof-v2"] + [ch[n] for n in fields])))
        return request("POST", path, b"{}", "ParanoidV2 " + ch["id"] + "." + signature)

    assert old_signed("register", "/v2/registration/commit")[0] == 200
    code, session = old_signed("session", "/v2/session")
    assert code == 200

    def session_proof(path):
        nonce = str(uuid.uuid4())
        fields = ("id", "epoch", "expires", "realm", "pin", "account", "device", "credential")
        signature = b64(auth.sign(lp(["paranoid-session-request-v1"] + [session[n] for n in fields]
                                    + [nonce, "GET", path, hashlib.sha256(b"").hexdigest()])))
        return "ParanoidSessionV2 " + session["id"] + "." + nonce + "." + signature

    for _ in range(2):
        path = "/v2/messages?after=0&limit=20"
        assert request("GET", path, auth=session_proof(path))[0] == 200
        assert connection.sock is original_socket, "signed requests must reuse original pinned socket"
    path = "/v2/events?after=0&limit=20"
    start = time.monotonic()
    code, page = request("GET", path, auth=session_proof(path))
    assert code == 200 and page == {"messages": [], "cursor": 0}, (code, page)
    assert 19 <= time.monotonic() - start < 24, "both nested deadlines must allow actual20s wait"
    assert connection.sock is original_socket, "long-poll must survive old15s absolute socket limit"
    print("PASS: same actual pinned TLS socket handles two signed requests and20s idle wait", flush=True)

    # Stay active beneath the new8s idle/header bound while approaching the real
    #120s absolute lifetime. No server timeout override or fake clock is used.
    while time.monotonic() - opened < 115:
        time.sleep(min(4, 115 - (time.monotonic() - opened)))
        assert request("GET", "/health")[0] == 200
        assert connection.sock is original_socket
    try:
        request("GET", path, auth=session_proof(path))
    except (OSError, http.client.HTTPException):
        pass
    else:
        raise AssertionError("absolute120s TLS lifetime must interrupt a late20s wait")
    age = time.monotonic() - opened
    assert 119 <= age <= 128, f"socket lifetime observation outside bound: {age}"
    connection.close()
    connection = connect()
    path = "/v2/messages?after=0&limit=20"
    assert request("GET", path, auth=session_proof(path))[0] == 200
    print(f"PASS: actual socket expired at{age:.3f}s; fresh signed nonce recovered on new pinned TLS", flush=True)
    connection.close()

    idle = connect()
    time.sleep(9)
    assert idle.sock.recv(1) == b"", "idle/header timeout must release permit before120s"
    idle.close()
    print("PASS: idle HTTP header socket closed within9s", flush=True)


if __name__ == "__main__":
    run()
