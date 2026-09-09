#!/usr/bin/env bash
# Pins the three locally-decidable behaviors of the federation oracle
# (tests/live/checks/instantiate/cognito-federation-live.sh):
#
#   1. MODE GATE — in LIVE_MODE=readonly the check exits 2 (skip) BEFORE
#      touching any tool or credential: the CI producer runs the suite
#      readonly, and a fixture-user write leaking into that path would be
#      an admin-AWS mutation under the scoped verifier role (and a
#      tier-contract violation). The stub PATH proves nothing else runs:
#      any aws/curl/kubectl invocation fails the test.
#
#   2. CLAIM DECODE — the exact id_token payload pipeline the check uses
#      (base64url + padding fix + jq assertions) against fixture JWTs:
#      the happy shape, a groups-missing shape, and a groups-as-string
#      shape (Keycloak emits a bare string when multivalued is off — the
#      jq `type == "array"` branch must handle both).
#
#   3. BROKER PRECONDITION — the kc_idp_hint redirect CHAIN, replayed from
#      canned hop headers: Keycloak's own /broker/<alias>/login hop first,
#      the Cognito authorize URL only after it (kp-8vs). Matching Cognito
#      against hop 1 alone made the check skip on a WORKING realm.
#
# The full flow (hosted UI → broker → token → kubectl) is live-only by
# nature; its hosted-UI leg was verified standalone against the real pool
# on build #5, and the whole path first runs recorded on the next
# from-scratch build.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/test-helpers.sh"
require_tool jq
require_tool python3

ROOT="$HERE/../.."
CHECK="$ROOT/tests/live/checks/instantiate/cognito-federation-live.sh"
[ -f "$CHECK" ] || { fail "check script present" "$CHECK missing"; summary; }
pass "check script present"

# ---- 1. readonly mode gate skips before any tool runs --------------------
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
for tool in aws curl kubectl python3; do
  cat > "$STUB_DIR/$tool" <<STUB
#!/usr/bin/env bash
echo "UNEXPECTED: $tool invoked in readonly mode" >&2
exit 99
STUB
  chmod +x "$STUB_DIR/$tool"
done

set +e
out="$(PATH="$STUB_DIR:$PATH" LIVE_MODE=readonly bash "$CHECK" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] \
  && pass "readonly mode exits 2 (skip)" \
  || fail "readonly mode gate" "rc=$rc, output: $(printf '%s' "$out" | head -2)"
printf '%s' "$out" | grep -q "UNEXPECTED" \
  && fail "readonly mode runs no tools" "a stubbed tool was invoked: $out" \
  || pass "readonly mode runs no tools"
printf '%s' "$out" | grep -qi "mutating" \
  && pass "skip message names the mutating-mode requirement" \
  || fail "skip message" "got: $out"

# ---- 2. the id_token claim-decode pipeline --------------------------------
# Mirrors the check's pipeline byte-for-byte:
#   cut -d. -f2 | python3 (urlsafe b64 + padding) → jq assertions.
decode() {
  printf '%s' "$1" | cut -d. -f2 | python3 -c 'import sys,base64,json; p=sys.stdin.read().strip(); p+="="*(-len(p)%4); print(json.dumps(json.loads(base64.urlsafe_b64decode(p))))'
}
mk_jwt() {  # $1 = payload json → unsigned fixture JWT (header.payload.sig)
  python3 -c 'import sys,base64,json
enc=lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
h=enc(json.dumps({"alg":"RS256","typ":"JWT"}).encode())
p=enc(sys.argv[1].encode())
print(f"{h}.{p}.fixture-signature")' "$1"
}

JWT_GOOD="$(mk_jwt '{"preferred_username":"oracle-x@test.invalid","groups":["k8s-viewers","other"]}')"
CLAIMS="$(decode "$JWT_GOOD")"
[ "$(printf '%s' "$CLAIMS" | jq -r '.preferred_username')" = "oracle-x@test.invalid" ] \
  && pass "decode: preferred_username extracted" \
  || fail "decode preferred_username" "claims: $CLAIMS"
HAS="$(printf '%s' "$CLAIMS" | jq -r --arg g "k8s-viewers" '(.groups // []) | if type == "array" then any(. == $g) else . == $g end')"
[ "$HAS" = "true" ] \
  && pass "decode: groups array membership detected" \
  || fail "groups array" "claims: $CLAIMS"

JWT_STR="$(mk_jwt '{"preferred_username":"u@x","groups":"k8s-viewers"}')"
HAS="$(decode "$JWT_STR" | jq -r --arg g "k8s-viewers" '(.groups // []) | if type == "array" then any(. == $g) else . == $g end')"
[ "$HAS" = "true" ] \
  && pass "decode: groups-as-bare-string handled" \
  || fail "groups string form" "single-string groups claim must satisfy the membership test"

JWT_NONE="$(mk_jwt '{"preferred_username":"u@x"}')"
HAS="$(decode "$JWT_NONE" | jq -r --arg g "k8s-viewers" '(.groups // []) | if type == "array" then any(. == $g) else . == $g end')"
[ "$HAS" = "false" ] \
  && pass "decode: absent groups claim is a miss, not an error" \
  || fail "groups absent form" "got '$HAS'"

# ---- 3. the broker precondition follows the redirect CHAIN ----------------
# kp-8vs (build #6, 2026-09-09): Keycloak 24 answers a kc_idp_hint
# authorization request with a 303 to its OWN broker entry point
# (/realms/platform/broker/cognito/login); the Cognito authorize URL is only
# the NEXT hop. A probe that matches Cognito against hop 1's Location alone
# can never see it, so a correctly brokered realm SKIPs forever. These cases
# drive the REAL check with canned hop headers (the stub-the-CLI shape of
# tests/unit/test_rds_live_check_vpc_logic.sh): the stub aws denies
# eks:ListClusters, so a check that gets PAST the broker precondition skips
# at the NEXT precondition instead — that is the observable difference.
FED_DOMAIN="oracle.invalid"
FED_HOST="auth.platform.${FED_DOMAIN}"
BROKER_HOP="https://${FED_HOST}/realms/platform/broker/cognito/login?session_code=stub&tab_id=stub"
COG_HOP="https://k8-platform-oracle.auth.us-east-1.amazoncognito.com/oauth2/authorize?client_id=stub&redirect_uri=https%3A%2F%2F${FED_HOST}%2Frealms%2Fplatform%2Fbroker%2Fcognito%2Fendpoint"

FED_BIN="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR" "$FED_BIN"' EXIT

cat > "$FED_BIN/curl" <<'CURLSTUB'
#!/usr/bin/env bash
# Canned Keycloak. Discovery is answered inline; every other request pops the
# next hop header fixture ($FIXDIR/hop<N>.h) and writes it to the -D file.
url="${@: -1}"
case "$url" in
  *.well-known/openid-configuration)
    printf '{"authorization_endpoint":"https://%s/realms/platform/protocol/openid-connect/auth","token_endpoint":"https://%s/realms/platform/protocol/openid-connect/token"}\n' \
      "$FED_HOST" "$FED_HOST"
    exit 0 ;;
esac
hdr=""; body=""; prev=""
for a in "$@"; do
  case "$prev" in -D) hdr="$a" ;; -o) body="$a" ;; esac
  prev="$a"
done
n=$(( $(cat "$FIXDIR/counter") + 1 )); printf '%s' "$n" > "$FIXDIR/counter"
if [ ! -f "$FIXDIR/hop$n.h" ]; then
  echo "UNEXPECTED-HOP $n -> $url" >&2; exit 7
fi
[ -n "$hdr" ] && cat "$FIXDIR/hop$n.h" > "$hdr"
[ -n "$body" ] && : > "$body"
exit 0
CURLSTUB

cat > "$FED_BIN/aws" <<'AWSSTUB'
#!/usr/bin/env bash
case "$*" in
  *"sts get-caller-identity"*) exit 0 ;;
  *"route53 list-hosted-zones"*)
    printf '{"HostedZones":[{"Name":"%s.","Config":{"PrivateZone":false}}]}\n' "$FED_DOMAIN"; exit 0 ;;
  *"secretsmanager get-secret-value"*)
    printf '{"issuer_url":"https://cognito-idp.us-east-1.amazonaws.com/us-east-1_stubpool"}\n'; exit 0 ;;
  *"cognito-idp get-group"*) exit 0 ;;
  # The precondition AFTER the broker block — denying it gives the probe a
  # distinct, unmistakable landing spot.
  *"eks list-clusters"*) echo "AccessDenied" >&2; exit 254 ;;
esac
echo "UNEXPECTED-AWS $*" >&2; exit 9
AWSSTUB

cat > "$FED_BIN/kubectl" <<'KSTUB'
#!/usr/bin/env bash
echo "UNEXPECTED: kubectl invoked in the broker-precondition probe" >&2
exit 99
KSTUB
chmod +x "$FED_BIN/curl" "$FED_BIN/aws" "$FED_BIN/kubectl"

# broker_probe <location...> — one arg per hop: a Location value, or "" for a
# 200 page with no Location. Sets PROBE_OUT / PROBE_RC.
broker_probe() {
  local fixdir; fixdir="$(mktemp -d)"
  local i=0 loc
  for loc in "$@"; do
    i=$((i + 1))
    if [ -n "$loc" ]; then
      printf 'HTTP/2 303 \r\ncache-control: no-store\r\nlocation: %s\r\n\r\n' "$loc" > "$fixdir/hop$i.h"
    else
      printf 'HTTP/2 200 \r\ncontent-type: text/html;charset=utf-8\r\n\r\n' > "$fixdir/hop$i.h"
    fi
  done
  printf '0' > "$fixdir/counter"
  set +e
  PROBE_OUT="$(env PATH="$FED_BIN:$PATH" FIXDIR="$fixdir" \
    FED_HOST="$FED_HOST" FED_DOMAIN="$FED_DOMAIN" \
    LIVE_MODE=mutating RUN_ID=ut-fed bash "$CHECK" 2>&1)"
  PROBE_RC=$?
  set -e
  rm -rf "$fixdir"
}

# (a) the real shape: broker hop, THEN Cognito.
broker_probe "$BROKER_HOP" "$COG_HOP"
if printf '%s' "$PROBE_OUT" | grep -qi "listclusters"; then
  pass "two-hop chain: broker precondition matches the FIRST OFF-HOST Location"
else
  fail "two-hop chain: broker precondition matches the first off-host Location" \
    "rc=$PROBE_RC out: $(printf '%s' "$PROBE_OUT" | tail -2 | tr '\n' ' ')"
fi

# (b) hop 1 already off-host to Cognito (no broker hop) still satisfies it.
broker_probe "$COG_HOP"
if printf '%s' "$PROBE_OUT" | grep -qi "listclusters"; then
  pass "single-hop chain: a direct Cognito redirect still satisfies the precondition"
else
  fail "single-hop chain satisfies the precondition" \
    "rc=$PROBE_RC out: $(printf '%s' "$PROBE_OUT" | tail -2 | tr '\n' ' ')"
fi

# (c) off-host, but NOT Cognito — skip, and say what was actually observed.
broker_probe "$BROKER_HOP" "https://accounts.google.com/o/oauth2/v2/auth?client_id=stub"
if [ "$PROBE_RC" -eq 2 ] && printf '%s' "$PROBE_OUT" | grep -q "accounts.google.com"; then
  pass "non-Cognito off-host target: skips and names the observed Location"
else
  fail "non-Cognito off-host target skips naming the observed Location" \
    "rc=$PROBE_RC out: $(printf '%s' "$PROBE_OUT" | tail -2 | tr '\n' ' ')"
fi

# (d) a 200 login page instead of a redirect — the genuine broker-less realm.
broker_probe ""
if [ "$PROBE_RC" -eq 2 ] && printf '%s' "$PROBE_OUT" | grep -q "no redirect"; then
  pass "200 login page: skips saying the request was not redirected"
else
  fail "200 login page skips saying the request was not redirected" \
    "rc=$PROBE_RC out: $(printf '%s' "$PROBE_OUT" | tail -2 | tr '\n' ' ')"
fi

# (e) a redirect loop that never leaves the Keycloak host is bounded.
broker_probe "$BROKER_HOP" "$BROKER_HOP" "$BROKER_HOP" "$BROKER_HOP" "$BROKER_HOP" "$BROKER_HOP"
if [ "$PROBE_RC" -eq 2 ] && printf '%s' "$PROBE_OUT" | grep -q "never left the Keycloak host"; then
  pass "on-host redirect loop: bounded, skips without hanging"
else
  fail "on-host redirect loop is bounded" \
    "rc=$PROBE_RC out: $(printf '%s' "$PROBE_OUT" | tail -2 | tr '\n' ' ')"
fi

summary
