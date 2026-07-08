#!/usr/bin/env python3
"""Build JWKS JSON for the AS public key (RSA, RS256)."""
import base64, json, sys
from cryptography.hazmat.primitives import serialization

with open("as_pub.pem", "rb") as f:
    pub = serialization.load_pem_public_key(f.read())

nums = pub.public_numbers()


def b64u(i: int) -> str:
    raw = i.to_bytes((i.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


jwks = {
    "keys": [
        {
            "kty": "RSA",
            "use": "sig",
            "kid": "mock-as-key-1",
            "alg": "RS256",
            "n": b64u(nums.n),
            "e": b64u(nums.e),
        }
    ]
}
print(json.dumps(jwks, indent=2))
