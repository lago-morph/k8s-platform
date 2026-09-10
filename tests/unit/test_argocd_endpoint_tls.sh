#!/usr/bin/env bash
# Hermetic unit test for the Argo CD endpoint TLS check (kp-nkz):
#   tests/live/checks/after/argocd-endpoint-tls-live.sh
#
# docs/site/reference/finished-platform.md claims the Argo CD endpoint serves a
# valid public certificate; the only build-time check of that hostname used
# `curl -sk` (verification DISABLED) and was continue-on-error, so nothing
# attested it. This test proves the new check's LOGIC without a cluster, without
# AWS and without network: fake `aws` (route53) + fake `curl` (scripted verdicts)
# on PATH, the check copied into a fake REPO_ROOT (the test_negatives_guard_fired
# idiom).
#
# Asserted properties:
#   (a) STATIC: the check never disables verification (no -k / --insecure) and
#       reads curl's own %{ssl_verify_result} verdict.
#   (b) valid chain + an answering endpoint    => PASS, emitting the synthetic
#       COVERS marker (and NOT a composed-MR kind).
#   (c) a REJECTED chain (curl TLS exit class) => FAIL, named as a certificate
#       finding.
#   (d) ssl_verify_result != 0 with a 200      => FAIL (a verified-looking 200
#       whose chain curl did not verify must never pass).
#   (e) endpoint unreachable (DNS/connect)     => FAIL, explicitly NOT reported
#       as a certificate finding.
#   (f) preconditions absent (no public zone, route53 denied, and — statically —
#       an absent aws/jq/curl) => SKIP, never a FAIL.
#   (g) the host is DISCOVERED from the hosted zone, never hardcoded.

set -uo pipefail
REAL_REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REAL_REPO_ROOT"

. tests/lib/assert.sh

CHECK_SRC="tests/live/checks/after/argocd-endpoint-tls-live.sh"
MARKER="platform.argocd/verified-tls"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---- (a) STATIC guards ------------------------------------------------------
echo "── argocd-tls: static — verification is never disabled ───────────────"
# assert_summary only `return`s — exit explicitly so a missing check reports once.
[ -f "$CHECK_SRC" ] || { _fail "check present" "missing $CHECK_SRC"; assert_summary; exit 1; }
SRC="$(cat "$CHECK_SRC")"
# Only the curl invocation matters; the prose explains why -k is banned.
CURL_LINES="$(printf '%s\n' "$SRC" | grep -n 'curl ' | grep -v '^[0-9]*:#')"
assert_eq "the curl invocation passes no -k/--insecure" "" \
  "$(printf '%s\n' "$CURL_LINES" | grep -E '(^|[[:space:]])-[a-zA-Z]*k([[:space:]]|$)|--insecure' || true)"
assert_contains "reads curl's own chain verdict" '%{ssl_verify_result}' "$SRC"
assert_contains "emits the synthetic marker, not an MR kind" "$MARKER" "$SRC"
assert_eq "the marker is NOT a composed-MR kind in the coverage oracle" "" \
  "$(grep -xF "$MARKER" tests/coverage/expected-coverage.txt || true)"
assert_eq "the host is not hardcoded (no literal domain)" "" \
  "$(printf '%s\n' "$SRC" | grep -nE 'argocd\.management\.[a-z0-9-]+\.[a-z]{2,}' || true)"
assert_contains "the host is derived from the public hosted zone" "list-hosted-zones" "$SRC"

# ---- fake REPO_ROOT so the check resolves its lib + helper ------------------
FAKE_ROOT="$WORKDIR/repo"
mkdir -p "$FAKE_ROOT/tests/live/checks/after" "$FAKE_ROOT/tests/live/lib" \
         "$FAKE_ROOT/tests/integration/lib" "$WORKDIR/bin"
ln -s "$REAL_REPO_ROOT/tests/live/lib/live-lib.sh"        "$FAKE_ROOT/tests/live/lib/live-lib.sh"
ln -s "$REAL_REPO_ROOT/tests/integration/lib/test-lib.sh" "$FAKE_ROOT/tests/integration/lib/test-lib.sh"
ln -s "$REAL_REPO_ROOT/tests/lib"                         "$FAKE_ROOT/tests/lib"
cp "$CHECK_SRC" "$FAKE_ROOT/tests/live/checks/after/"
CHECK="$FAKE_ROOT/tests/live/checks/after/$(basename "$CHECK_SRC")"

# fake aws: sts ok; route53 list-hosted-zones returns one public zone (and one
# private zone first, to prove the selector skips private zones).
write_aws() {
  cat > "$WORKDIR/bin/aws" <<AWSEOF
#!/usr/bin/env bash
case "\$*" in
  *get-caller-identity*) printf '{"Account":"123456789012"}\n'; exit 0 ;;
  *list-hosted-zones*)   printf '%s\n' '${1}'; exit ${2:-0} ;;
  *) exit 0 ;;
esac
AWSEOF
  chmod +x "$WORKDIR/bin/aws"
}
ZONES_OK='{"HostedZones":[{"Name":"internal.example.","Config":{"PrivateZone":true}},{"Name":"example-platform.test.","Config":{"PrivateZone":false}}]}'
ZONES_NONE='{"HostedZones":[{"Name":"internal.example.","Config":{"PrivateZone":true}}]}'

# fake curl: <http_code> <ssl_verify_result> <exit-code> [stderr-text]
write_curl() {
  cat > "$WORKDIR/bin/curl" <<CURLEOF
#!/usr/bin/env bash
# Record the argv the check used, so the test can prove what was requested.
printf '%s\n' "\$*" >> "$WORKDIR/curl.argv"
[ -n "${4:-}" ] && printf '%s\n' "${4:-}" >&2
printf '%s %s' "${1}" "${2}"
exit ${3}
CURLEOF
  chmod +x "$WORKDIR/bin/curl"
}

# run_check — echo "<rc>|<output>" with the poll collapsed to a single attempt.
run_check() {
  local out rc
  set +e
  out="$(env PATH="$WORKDIR/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin" \
          AWS_REGION=us-east-1 \
          ARGOCD_TLS_POLL_MAX=0 ARGOCD_TLS_POLL_INTERVAL=0 \
          bash "$CHECK" 2>&1)"
  rc=$?
  set -e
  printf '%s|%s' "$rc" "$out"
}
rc_of()  { printf '%s' "${1%%|*}"; }
out_of() { printf '%s' "${1#*|}"; }

LIVE_RC_PASS=0
LIVE_RC_SKIP=2

# ---- (b) valid chain + answering endpoint => PASS ---------------------------
echo ""
echo "── argocd-tls: (b) verified chain + http 200 => PASS ─────────────────"
write_aws "$ZONES_OK"; write_curl 200 0 0; : > "$WORKDIR/curl.argv"
R="$(run_check)"
assert_eq "verified chain + 200 ⇒ pass (0)" "$LIVE_RC_PASS" "$(rc_of "$R")"
assert_contains "emits COVERS $MARKER" "COVERS $MARKER" "$(out_of "$R")"
# (g) the URL was built from the PUBLIC zone, with the private zone ignored.
assert_contains "targets argocd.management.<discovered domain>" \
  "https://argocd.management.example-platform.test/" "$(cat "$WORKDIR/curl.argv")"
assert_eq "never sends -k/--insecure on the wire" "" \
  "$(grep -E '(^| )-[a-zA-Z]*k( |$)|--insecure' "$WORKDIR/curl.argv" || true)"

# ---- (c) rejected chain => FAIL, named as a certificate finding -------------
echo ""
echo "── argocd-tls: (c) curl TLS exit 60 => FAIL (certificate finding) ────"
write_aws "$ZONES_OK"; write_curl "" "" 60 "curl: (60) SSL certificate problem: unable to get local issuer certificate"
R="$(run_check)"
assert_eq "rejected chain ⇒ FAIL (exit 1)" 1 "$(rc_of "$R")"
assert_contains "the failure names the certificate" "CERTIFICATE DID NOT VALIDATE" "$(out_of "$R")"

# ---- (d) a 200 whose chain curl did not verify => FAIL ----------------------
echo ""
echo "── argocd-tls: (d) http 200 but ssl_verify_result!=0 => FAIL ─────────"
write_aws "$ZONES_OK"; write_curl 200 20 0
R="$(run_check)"
assert_eq "unverified chain with a 200 ⇒ FAIL (exit 1)" 1 "$(rc_of "$R")"
assert_contains "reported as a certificate finding" "CERTIFICATE DID NOT VALIDATE" "$(out_of "$R")"

# ---- (e) unreachable endpoint => FAIL, NOT a certificate finding ------------
echo ""
echo "── argocd-tls: (e) connect failure => FAIL, not a cert claim ─────────"
write_aws "$ZONES_OK"; write_curl "" "" 7 "curl: (7) Failed to connect"
R="$(run_check)"
assert_eq "connect failure ⇒ FAIL (exit 1)" 1 "$(rc_of "$R")"
assert_contains "says it did not answer" "did not answer" "$(out_of "$R")"
assert_contains "explicitly NOT a certificate finding" "NOT a certificate finding" "$(out_of "$R")"
assert_eq "does not claim a certificate problem" "" \
  "$(printf '%s' "$(out_of "$R")" | grep -o 'CERTIFICATE DID NOT VALIDATE' || true)"

# ---- (f) preconditions absent => SKIP --------------------------------------
echo ""
echo "── argocd-tls: (f) missing preconditions => SKIP, never FAIL ─────────"
write_aws "$ZONES_NONE"; write_curl 200 0 0
assert_eq "no public hosted zone ⇒ skip (2)" "$LIVE_RC_SKIP" "$(rc_of "$(run_check)")"
write_aws "" 1
assert_eq "route53:ListHostedZones denied ⇒ skip (2)" "$LIVE_RC_SKIP" "$(rc_of "$(run_check)")"
# An absent tool is the shared boilerplate precondition every after-tier check
# carries; assert it statically (a PATH with no curl cannot be synthesized
# without also hiding the coreutils the check legitimately needs).
assert_contains "curl/aws/jq absence is a skip precondition, not a FAIL" \
  'for bin in aws jq curl' "$SRC"
assert_contains "  ...and that loop skips rather than failing" \
  '|| skip "$bin not on PATH' "$SRC"

assert_summary
