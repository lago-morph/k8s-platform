#!/usr/bin/env bash
# LIVE behavioral check (after tier) — the Argo CD endpoint answers over TLS that
# VALIDATES against the public trust store (kp-nkz).
#
# The claim this attests: docs/site/reference/finished-platform.md's endpoint
# inventory row
#   | https://argocd.management.<domain> | Argo CD UI answering with a valid certificate |
# Nothing attested it. The only build-time check of that hostname is the
# `[management] argocd-url` step in .github/workflows/terraform-test.yml, which
# curls with `-sk` (verification DISABLED) and is `continue-on-error` — it can
# neither prove nor fail on certificate validity. The claim is nonetheless TRUE:
# measured 2026-09-09 against the build-#6 hub, curl with verification ENABLED
# returned http=200 ssl_verify_result=0. This check is that measurement, wired.
#
# It is the paired oracle for tests/unit/test_management_ingress_cert_coverage.sh:
# that test proves STATICALLY that the *.management.<domain> cert covers the
# hostname the ingress publishes; this one proves the live endpoint actually
# serves a chain a strict verifier accepts (the OI-2026-06-05-5 failure mode was
# exactly a presented cert that did not name-match, which `curl -sk` masked).
#
# NEVER passes -k / --insecure: verification IS the assertion.
#
# Emits `covers "platform.argocd/verified-tls"` — an additive synthetic marker
# (the hello-e2e / spoke-storage idiom), not a composed-MR kind: no managed
# resource maps to "the endpoint serves a valid chain", so it must never be
# mistaken for the ACM Certificate kind's coverage, and it is not in
# LIVE_EXPECT_FULL.
#
# The host is DISCOVERED, never hardcoded (the account and domain rotate): the
# public hosted zone gives the base domain, and the management services sit one
# label under `management.<domain>` (terraform/management/helm.tf).
#
# Exit-code contract (tests/live/lib/live-lib.sh): 0=pass(+covers), 2=skip,
# other=fail. Read-only (a single curl GET, body discarded) — safe in `full` +
# `verify-only`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/tests/live/lib/live-lib.sh"

MARKER="platform.argocd/verified-tls"

# Bounded poll (mirrors hello-e2e-live.sh): ExternalDNS/NLB settling must not
# read as an invalid certificate. Seams keep the unit harness instant.
POLL_MAX="${ARGOCD_TLS_POLL_MAX:-120}"
POLL_INTERVAL="${ARGOCD_TLS_POLL_INTERVAL:-15}"

# ── Tooling / credential preconditions — not-applicable (skip), not a failure ──
for bin in aws jq curl; do
  command -v "$bin" >/dev/null 2>&1 \
    || skip "$bin not on PATH (Argo CD endpoint TLS check not exercisable here)"
done
aws sts get-caller-identity >/dev/null 2>&1 \
  || skip "no usable AWS credentials in this environment"

# ── Discover the host (never hardcoded — the account/domain rotate) ───────────
log "deriving public hosted-zone domain via aws route53 list-hosted-zones"
ZONES_JSON="$(aws route53 list-hosted-zones --output json 2>/dev/null)" \
  || skip "route53:ListHostedZones not permitted / unavailable here"

ZONE_NAME="$(printf '%s' "$ZONES_JSON" | jq -r '
  .HostedZones[]
  | select(.Config.PrivateZone == false)
  | .Name' | head -1)"
if [ -z "$ZONE_NAME" ] || [ "$ZONE_NAME" = "null" ]; then
  skip "no public hosted zone found in this account (Argo CD endpoint precondition not met)"
fi

DOMAIN="${ZONE_NAME%.}"                       # strip the trailing dot
HOST="argocd.management.${DOMAIN}"
URL="https://${HOST}/"
log "public domain: $DOMAIN"
log "target URL: $URL (TLS verification ENABLED — no -k)"

# ── The assertion: TLS validates, and the endpoint answers ───────────────────
# %{ssl_verify_result} is curl's own verdict on the chain: 0 == verified. curl
# exit codes in the TLS family (35/51/58/59/60/77/83) mean the handshake or the
# chain itself was rejected — a CERTIFICATE finding. Anything else that fails
# (DNS, connect, timeout) is NOT a certificate finding and must not be reported
# as one.
START="$(date +%s)"
ok_tls=0
last_rc=""; last_code=""; last_verify=""; last_err=""
ERR_FILE="$(mktemp)"

while true; do
  ELAPSED=$(( $(date +%s) - START ))
  # No `set -e` toggling here: this file runs under `set -uo pipefail` (via
  # lib/live-lib.sh) and a failing curl is EXPECTED input, not an abort. Turning
  # errexit on would also swallow every diagnostic line after the first `ng`.
  RESP="$(curl -sS -o /dev/null --max-time 10 --connect-timeout 5 \
            -w '%{http_code} %{ssl_verify_result}' "$URL" 2>"$ERR_FILE")"
  last_rc=$?
  last_code="$(printf '%s' "$RESP" | awk '{print $1}')"
  last_verify="$(printf '%s' "$RESP" | awk '{print $2}')"
  last_err="$(tr -d '\r' < "$ERR_FILE" | head -2 | tr '\n' ' ')"

  if [ "$last_rc" -eq 0 ] && [ "${last_verify:-1}" = "0" ] \
     && [ -n "$last_code" ] && [ "$last_code" -lt 400 ] 2>/dev/null; then
    ok_tls=1
    break
  fi
  log "  attempt at ${ELAPSED}s: curl_exit=$last_rc http=${last_code:-none} ssl_verify_result=${last_verify:-none} ${last_err}"
  [ "$ELAPSED" -ge "$POLL_MAX" ] && break
  sleep "$POLL_INTERVAL"
done
rm -f "$ERR_FILE"

if [ "$ok_tls" -ne 1 ]; then
  case "$last_rc" in
    35|51|58|59|60|77|83)
      ng "CERTIFICATE DID NOT VALIDATE for $URL (curl exit $last_rc, ssl_verify_result=${last_verify:-none}): ${last_err}"
      ng "  The inventory row in docs/site/reference/finished-platform.md claims this"
      ng "  endpoint serves a valid public certificate. Either the *.management.<domain>"
      ng "  ACM cert is not the one the NLB presents (the OI-2026-06-05-5 name-mismatch"
      ng "  class — see tests/unit/test_management_ingress_cert_coverage.sh), it is not"
      ng "  ISSUED, or the chain is incomplete. Fix the platform or correct the claim."
      ;;
    *)
      if [ "${last_verify:-}" != "" ] && [ "${last_verify:-0}" != "0" ]; then
        ng "CERTIFICATE DID NOT VALIDATE for $URL (ssl_verify_result=$last_verify, http=${last_code:-none})"
      else
        ng "$URL did not answer within ${POLL_MAX}s (curl exit $last_rc, http=${last_code:-none}): ${last_err}"
        ng "  This is NOT a certificate finding: the endpoint never completed a request."
        ng "  Indicates the management NLB is unhealthy, ingress-nginx is not routing,"
        ng "  argocd-server is not Ready, or ExternalDNS has not published $HOST."
      fi
      ;;
  esac
  exit 1
fi

ok "$URL answered http=$last_code with ssl_verify_result=$last_verify (chain VALIDATED against the public trust store)"
covers "$MARKER"
exit "$LIVE_RC_PASS"
