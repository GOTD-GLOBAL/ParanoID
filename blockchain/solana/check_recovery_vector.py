#!/usr/bin/env python3
"""Independent public-vector reproduction; NEVER accept a user's mnemonic/key.

BIP39 PBKDF2 and SLIP-0010 HMAC from Python stdlib; Ed25519 from
cryptography/OpenSSL, independent of Rust bip39/ed25519-dalek-bip32.
Sources: BIP-0039 and satoshilabs/slips slip-0010.md.
This is test-only code, not a production derivation implementation.
"""
import hashlib
import hmac
import json
import platform
import struct
import unicodedata
import cryptography
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat


def derive(seed, indices):
    node = hmac.digest(b"ed25519 seed", seed, "sha512")
    for index in indices:
        node = hmac.digest(node[32:], b"\0" + node[:32] + struct.pack(">I", index | 0x80000000), "sha512")
    return Ed25519PrivateKey.from_private_bytes(node[:32]).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


def base58(data):
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    number = int.from_bytes(data, "big")
    result = ""
    while number:
        number, digit = divmod(number, 58)
        result = alphabet[digit] + result
    return "1" * (len(data) - len(data.lstrip(b"\0"))) + result


# Published SLIP-0010 vector1; independently validates this test implementation.
assert derive(bytes(range(16)), [0, 1, 2, 2, 1000000000]).hex() == "3c24da049451555d51a7014a37337aa4e12d41e485abccfa46b47dfb2af54b7a"
# Public 256-bit all-zero BIP39 entropy: 23 times abandon followed by art.
phrase = " ".join(["abandon"] * 23 + ["art"])
seed = hashlib.pbkdf2_hmac("sha512", unicodedata.normalize("NFKD", phrase).encode(), b"mnemonic", 2048, 64)
address = base58(derive(seed, [44, 501, 0, 0]))
assert address == "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx"
print(json.dumps({"result": "PASS", "python": platform.python_version(), "cryptography": cryptography.__version__, "path": "m/44'/501'/0'/0'", "entropy": "public 32 zero bytes", "passphrase": "empty", "address": address, "published_slip0010_vector": "PASS"}, indent=2))
