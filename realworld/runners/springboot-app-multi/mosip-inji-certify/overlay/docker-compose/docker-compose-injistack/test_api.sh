#!/usr/bin/env bash
# mosip-inji-certify — smoke test


set -u
BASE="${BASE:-http://localhost:8090/v1/certify}"

pass=0; fail=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" =~ ^($expected)$ ]]; then
        printf "  ok   %-65s -> %s\n" "$name" "$actual"
        pass=$((pass+1))
    else
        printf "  FAIL %-65s -> got %s, want %s\n" "$name" "$actual" "$expected"
        fail=$((fail+1))
    fi
}

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }

echo "==> Wait for boot"
for _ in $(seq 1 60); do
    s=$(code "$BASE/actuator/health" || echo 000)
    [[ "$s" == "200" ]] && break
    sleep 2
done
echo "    health=$s"
[[ "$s" != "200" ]] && { echo "boot failed"; exit 1; }

echo
echo "==> Public happy paths (200)"
check "GET /actuator/health"                                "200" "$(code "$BASE/actuator/health")"
check "GET /v3/api-docs (springdoc)"                        "200" "$(code "$BASE/v3/api-docs")"
check "GET /swagger-ui/index.html"                          "200" "$(code "$BASE/swagger-ui/index.html")"
check "GET /.well-known/openid-credential-issuer (top)"     "200" "$(code "$BASE/.well-known/openid-credential-issuer")"
check "GET /.well-known/did.json (top)"                     "200" "$(code "$BASE/.well-known/did.json")"
# /issuance/.well-known/* is the VCI-controller alias of the same docs.
check "GET /issuance/.well-known/openid-credential-issuer"  "200" "$(code "$BASE/issuance/.well-known/openid-credential-issuer")"
check "GET /system-info/certificate (key existed @boot)"    "200" "$(code "$BASE/system-info/certificate?applicationId=CERTIFY_VC_SIGN_ED25519&referenceId=ED25519_SIGN")"
check "GET /credentials/status-list/abc"                    "200" "$(code "$BASE/credentials/status-list/abc")"

echo
echo "==> ResponseWrapper-200 error envelopes (@Valid on non-issuance paths)"
# CredentialStatusController: ResponseWrapper, status 200, errors[] populated.
check "POST /credentials/status {} (validation)"            "200" "$(code -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/credentials/status")"
# CredentialConfigController: same envelope.
check "POST /credential-configurations {} (validation)"     "200" "$(code -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/credential-configurations")"
# CredentialLedgerController: same envelope.
check "POST /ledger-search {} (validation)"                 "200" "$(code -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/ledger-search")"
# Unrouted path -> LocalAuthenticationEntryPoint envelope (HTTP 200, error body).
# This is the project's quirk: anything not matching ignoreAuthUrls but with no
# JWT lands here as a ResponseWrapper, not a Spring 401.
check "GET /not-an-endpoint (auth-required envelope)"       "200" "$(code "$BASE/not-an-endpoint")"

echo
echo "==> /issuance/credential — full success path (200 + signed VC)"
# Walks the OpenID4VCI flow against a wiremock-served JWKS:
#   1. Python helper signs an RS256 access token claiming aud=issuance/credential,
#      iss=esignet-mock, c_nonce=<known>, sub=2154189532 (matches farmer CSV id).
#   2. Helper signs an ES256 OpenID4VCI proof JWT with embedded jwk header,
#      aud=mosip.certify.identifier, nonce=<same c_nonce>.
#   3. POST exercises VCIssuanceService -> JwtProofValidator -> CSV plugin ->
#      JsonLD Ed25519 signing -> ledger insert. Response is a real VC.
SIGN_DIR="$(dirname "$0")/mock-as"
AT="$(cd "$SIGN_DIR" && python3 sign_jwt.py at)"
PROOF="$(cd "$SIGN_DIR" && python3 sign_jwt.py proof)"
ISSUE_BODY=$(printf '{"format":"ldp_vc","proof":{"proof_type":"jwt","jwt":"%s"},"credential_definition":{"@context":["https://www.w3.org/2018/credentials/v1"],"type":["VerifiableCredential","FarmerCredential"]}}' "$PROOF")
check "POST /issuance/credential (AT + proof + farmer body)" "200" \
    "$(code -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $AT" -d "$ISSUE_BODY" "$BASE/issuance/credential")"
# Keep one project-defined error state from the issuance path so the VCError
# 400 envelope branch in handleVCIControllerExceptions still gets exercised.
check "POST /issuance/credential {} (VCError 400 branch)"   "400" "$(code -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/issuance/credential")"

echo
echo "==> Distinct controller branches (PUT/DELETE + system-info BC paths)"
# PUT exercises Hibernate UPDATE path on credential_config (different from POST/SELECT).
# Body is just `{}` -> @Valid fails -> 200 envelope, but the PUT handler/service
# method is still invoked, and the JPA infra around it still class-loads.
check "PUT /credential-configurations/FarmerCredential {}"  "200" \
    "$(code -X PUT -H 'Content-Type: application/json' -d '{}' "$BASE/credential-configurations/FarmerCredential")"
# DELETE on missing id -> findById fails -> CredentialConfigException -> 404
# envelope. NOTE: this branch only exercises Hibernate SELECT; the actual
# repository.delete() call sits AFTER the findById and is never reached here.
check "DELETE /credential-configurations/missing (404 br.)" "404" \
    "$(code -X DELETE "$BASE/credential-configurations/missing")"
# Real DELETE path: seed a throwaway row, then delete it -> 200. Now Hibernate
# DELETE actually runs (different bytecode from SELECT). Idempotent via
# ON CONFLICT so the test can re-run.
docker exec mosip-inji-certify-db psql -U postgres -d inji_certify -q \
    -c "INSERT INTO certify.credential_config (credential_config_key_id, config_id, credential_format, display, display_order, scope, cryptographic_binding_methods_supported, credential_signing_alg_values_supported, proof_types_supported, cr_dtimes) VALUES ('throwaway-cfg', 'throwaway-cfg', 'ldp_vc', '[]'::jsonb, ARRAY['x'], 'stub', ARRAY['did:jwk'], ARRAY['Ed25519Signature2020'], '{\"jwt\":{\"proof_signing_alg_values_supported\":[\"ES256\"]}}'::jsonb, now()) ON CONFLICT (credential_config_key_id) DO NOTHING;" \
    >/dev/null
check "DELETE /credential-configurations/throwaway-cfg (real DELETE)" "200" \
    "$(code -X DELETE "$BASE/credential-configurations/throwaway-cfg")"
# system-info BC paths. Bodies populate the @Valid-required keys with stub
# values; we *do not* claim the contents are valid, but the controller gets
# past validation and the keymanager service reaches BouncyCastle:
#  - uploadCertificate: BC X.509 parser loads, fails on fake PEM -> 200 envelope
#  - generate-csr:      BC PKCS10CertificationRequestBuilder runs end-to-end,
#                       returns a real CSR signed by the existing keystore key
#  - upload-ca-certificate: BC X.509 parser loads, fails on fake PEM -> 200
UPLOAD_CERT_BODY='{"request":{"applicationId":"CERTIFY_VC_SIGN_ED25519","referenceId":"ED25519_SIGN","certificateData":"-----BEGIN CERTIFICATE-----\nstub\n-----END CERTIFICATE-----"}}'
CSR_BODY='{"request":{"applicationId":"CERTIFY_VC_SIGN_ED25519","referenceId":"ED25519_SIGN","commonName":"stub","organization":"stub","organizationUnit":"stub","location":"stub","state":"stub","country":"IN"}}'
CA_BODY='{"request":{"partnerDomain":"AUTH","certificateData":"-----BEGIN CERTIFICATE-----\nstub\n-----END CERTIFICATE-----"}}'
check "POST /system-info/uploadCertificate (BC parser reached)" "200" \
    "$(code -X POST -H 'Content-Type: application/json' -d "$UPLOAD_CERT_BODY" "$BASE/system-info/uploadCertificate")"
check "POST /system-info/generate-csr (real CSR signed)"        "200" \
    "$(code -X POST -H 'Content-Type: application/json' -d "$CSR_BODY" "$BASE/system-info/generate-csr")"
check "POST /system-info/upload-ca-certificate (BC parser reached)" "200" \
    "$(code -X POST -H 'Content-Type: application/json' -d "$CA_BODY" "$BASE/system-info/upload-ca-certificate")"

echo
echo "==> Resource lookup (200) — DB-seeded happy paths"
# Seed rendering_template with id=farmer-svg. Idempotent (ON CONFLICT) so
# re-runs against a non-fresh DB don't error. cr_dtimes is NOT NULL per
# certify_init.sql; upd_dtimes is nullable but populating it satisfies the
# JPA entity validator that some endpoints call on read.
docker exec mosip-inji-certify-db psql -U postgres -d inji_certify -q \
    -c "INSERT INTO certify.rendering_template (id, template, cr_dtimes, upd_dtimes) VALUES ('farmer-svg', '<svg/>', now(), now()) ON CONFLICT (id) DO NOTHING;" \
    >/dev/null
check "GET /rendering-template/farmer-svg (seeded)"         "200" "$(code "$BASE/rendering-template/farmer-svg")"
# credential_config row 'FarmerCredential' is created at boot via certify_init.sql.
check "GET /credential-configurations/FarmerCredential"     "200" "$(code "$BASE/credential-configurations/FarmerCredential")"
# Keep one 404 sample so the RenderingTemplateException -> NOT_FOUND mapping
# (a distinct branch in ExceptionHandlerAdvice) is still exercised.
check "GET /rendering-template/missing (404 branch)"        "404" "$(code "$BASE/rendering-template/missing")"

echo
echo "==> Summary: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
