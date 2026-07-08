#!/usr/bin/env python3
"""Sign access-token JWT (RS256) and proof JWT (ES256) for /issuance/credential.

Usage:
  sign_jwt.py at        # prints access-token JWT
  sign_jwt.py proof     # prints OpenID4VCI proof JWT (with embedded JWK header)
"""
import base64
import json
import sys
import time
import uuid

import jwt as pyjwt
from cryptography.hazmat.primitives import serialization

# claim values must line up with certify config:
#   mosip.certify.authn.issuer-uri = ${authorization.url}/v1/esignet
#                                  = https://esignet-mock.collab.mosip.net/v1/esignet
#   mosip.certify.authn.allowed-audiences contains
#     ${domain.url}${servlet.path}/issuance/credential
#     = http://localhost:8090/v1/certify/issuance/credential
ISSUER = "https://esignet-mock.collab.mosip.net/v1/esignet"
AUDIENCE = "http://localhost:8090/v1/certify/issuance/credential"
CLIENT_ID = "test-client"
SUBJECT = "2154189532"  # matches an `id` in farmer_identity_data.csv
C_NONCE = "test-cnonce-12345"


def _b64u(i: int) -> str:
    raw = i.to_bytes((i.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def access_token() -> str:
    with open("as_priv.pem", "rb") as f:
        priv = f.read()
    now = int(time.time())
    claims = {
        "iss": ISSUER,
        "aud": [AUDIENCE],
        "sub": SUBJECT,
        "client_id": CLIENT_ID,
        "iat": now - 5,
        "exp": now + 3600,
        "scope": "mock_identity_vc_ldp",
        "c_nonce": C_NONCE,
        "c_nonce_expires_in": 3600,
        "jti": str(uuid.uuid4()),
    }
    return pyjwt.encode(
        claims, priv, algorithm="RS256", headers={"kid": "mock-as-key-1", "typ": "JWT"}
    )


def proof_jwt() -> str:
    """Build an OpenID4VCI proof+jwt with embedded jwk in header."""
    with open("proof_priv.pem", "rb") as f:
        priv = serialization.load_pem_private_key(f.read(), password=None)
    pub = priv.public_key()
    nums = pub.public_numbers()
    # P-256 coords are 32 bytes
    x_b = nums.x.to_bytes(32, "big")
    y_b = nums.y.to_bytes(32, "big")
    holder_jwk = {
        "kty": "EC",
        "crv": "P-256",
        "x": base64.urlsafe_b64encode(x_b).rstrip(b"=").decode(),
        "y": base64.urlsafe_b64encode(y_b).rstrip(b"=").decode(),
    }
    header = {
        "alg": "ES256",
        "typ": "openid4vci-proof+jwt",
        "jwk": holder_jwk,
    }
    now = int(time.time())
    # JwtProofValidator.validate() requires aud == mosip.certify.identifier,
    # which resolves to mosip.certify.domain.url = http://localhost:8090.
    claims = {
        "iss": CLIENT_ID,
        "aud": "http://localhost:8090",
        "iat": now - 5,
        "nonce": C_NONCE,
    }
    with open("proof_priv.pem", "rb") as f:
        priv_pem = f.read()
    return pyjwt.encode(claims, priv_pem, algorithm="ES256", headers=header)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "at"
    print(access_token() if cmd == "at" else proof_jwt())
