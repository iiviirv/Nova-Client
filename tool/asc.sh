#!/bin/zsh
# One authenticated App Store Connect API call.
#
# Usage:  tool/asc.sh <path> [METHOD] [json-body]
#         tool/asc.sh "builds?filter[app]=6804490430&limit=5"
#         tool/asc.sh "betaGroups/<id>/relationships/builds" POST '{"data":[...]}'
#
# Prints the response body on stdout, so callers can pipe it into python3.
# Exits non-zero on an HTTP error and prints the body to stderr.
#
# No dependencies beyond openssl and python3's standard library. PyJWT and
# cryptography are not installed system-wide here, and a release script that
# needs a virtualenv to exist is a release script that breaks on the machine
# that has not made one. openssl does the ECDSA; python3 does the base64url and
# the DER unpacking, both of which are stdlib.
set -o pipefail

PATH_Q="${1:?usage: asc.sh <path> [METHOD] [body]}"
METHOD="${2:-GET}"
BODY="${3:-}"

KEYID="${ASC_KEY_ID:-4NF8HTUX29}"
ISSUER="${ASC_ISSUER:-048b417e-9426-428a-a694-f18b1384a7d0}"
KEY="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$KEYID.p8}"
[[ -f "$KEY" ]] || { echo "!! no App Store Connect key at $KEY" >&2; exit 1 }

# ES256, assembled by hand.
#
# The one non-obvious step is the signature. openssl emits ECDSA as DER (a
# SEQUENCE of two INTEGERs, variable length, sometimes with a leading zero byte
# so a high bit does not read as negative). A JWT wants the raw r||s, each
# left-padded to exactly 32 bytes. Handing the DER over unchanged produces a
# token Apple rejects as malformed, with no hint as to why.
sign_input="$(python3 - "$KEYID" "$ISSUER" <<'PY'
import base64, json, sys, time
kid, iss = sys.argv[1], sys.argv[2]
def b64(o):
    return base64.urlsafe_b64encode(json.dumps(o, separators=(',', ':')).encode()).rstrip(b'=').decode()
now = int(time.time())
head = b64({"alg": "ES256", "kid": kid, "typ": "JWT"})
body = b64({"iss": iss, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"})
print(f"{head}.{body}")
PY
)" || exit 1

sig_der="$(mktemp)"
printf '%s' "$sign_input" | openssl dgst -sha256 -sign "$KEY" -out "$sig_der" || {
  rm -f "$sig_der"; echo "!! signing failed" >&2; exit 1
}
sig="$(python3 - "$sig_der" <<'PY'
import base64, sys
der = open(sys.argv[1], 'rb').read()
# SEQUENCE (0x30) len, then two INTEGERs (0x02) len value.
i = 2 if der[1] < 0x80 else 3 + (der[1] & 0x7f) - 1
out = b''
for _ in range(2):
    assert der[i] == 0x02, 'not an ASN.1 INTEGER'
    n = der[i + 1]
    v = der[i + 2:i + 2 + n].lstrip(b'\x00')
    out += v.rjust(32, b'\x00')
    i += 2 + n
print(base64.urlsafe_b64encode(out).rstrip(b'=').decode())
PY
)" || { rm -f "$sig_der"; exit 1 }
rm -f "$sig_der"

TOKEN="$sign_input.$sig"
URL="https://api.appstoreconnect.apple.com/v1/$PATH_Q"

out="$(mktemp)"
# -g (globoff) is load-bearing: App Store Connect filters are spelled
# filter[app]=..., and without it curl reads the brackets as a glob range and
# refuses the URL with "bad range in URL position".
if [[ -n "$BODY" ]]; then
  code="$(curl -sS -g -o "$out" -w '%{http_code}' -X "$METHOD" "$URL" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$BODY")"
else
  code="$(curl -sS -g -o "$out" -w '%{http_code}' -X "$METHOD" "$URL" \
    -H "Authorization: Bearer $TOKEN")"
fi

if [[ "$code" -ge 400 ]]; then
  echo "!! App Store Connect returned $code for $METHOD $PATH_Q" >&2
  cat "$out" >&2; rm -f "$out"; exit 1
fi
cat "$out"; rm -f "$out"
