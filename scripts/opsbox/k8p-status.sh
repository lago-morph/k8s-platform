#!/usr/bin/env bash
# k8p-status.sh — one screen that says where the platform actually is.
#
# Read-only. Safe to run at any time, including in the middle of a build, and
# it never changes anything. Every line is a live read against AWS or the
# cluster, so it is true of the world rather than true of a CI run.
#
# Exit code: 0 if every stage is green, 1 otherwise — so it can gate a script.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$HERE/lib.sh"

FAILED=0
stage() {
  label="$1"; fn="$2"; detail="${3:-}"
  if "$fn" 2>/dev/null; then
    green "$label"
  else
    red "$label"
    [ -n "$detail" ] && info "$detail"
    FAILED=1
  fi
}

head_ "PLATFORM STATUS  $(date -u +%FT%TZ)"

acct="$(account_id)"
dom="$(platform_domain)"
info "account ${acct:-<no credentials>}   region ${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
info "domain  ${dom:-<no public hosted zone>}"

head_ "Prerequisites"
stage "credentials"            check_credentials "no AWS identity — is this running on the ops box?"
stage "public hosted zone"     check_zone        "the account must carry a public Route53 zone; the build discovers it"

head_ "Build stages"
stage "1. base applied"        check_base        "run Terraform Test with phase=base, action=apply-and-verify"
stage "2. management applied"  check_management  "run Terraform Test with phase=management, action=apply-and-verify"
stage "3. gate 1 complete"     check_gate1       "the four published facts plus a Ready node group; k8p-bringup.sh syncs it"
stage "4. gate 2 complete"     check_gate2       "XSpokeAccess Ready; k8p-bringup.sh syncs it"
stage "5. stack converged"     check_converged   "every Application Synced/Healthy except workload1-cluster (OutOfSync by design)"

head_ "Behaviour"
stage "hello endpoint 200"     check_endpoint    "https://hello.platform.${dom:-<domain>}/ is the behavioural gate"

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '%s  ALL GREEN%s — the platform is up and serving.\n\n' "$C_BOLD$C_GREEN" "$C_OFF"
else
  printf '%s  NOT COMPLETE%s — run %sk8p-bringup.sh%s to continue from here.\n\n' \
    "$C_BOLD$C_YELLOW" "$C_OFF" "$C_BOLD" "$C_OFF"
fi
exit "$FAILED"
