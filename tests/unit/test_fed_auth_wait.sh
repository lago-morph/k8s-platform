#!/usr/bin/env bash
# kp-2al.57 — fed_auth_wait (tests/live/lib/live-lib.sh): the federation
# check must ride out EKS's documented OIDC-association lag (the API answers
# Unauthorized for minutes after the IdP config is ACTIVE) without waiting
# forever, renew short-lived tokens while it waits, and stop at once on any
# other failure. Hermetic: stub try/refresh functions, 0 s poll interval.
set -uo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
. tests/lib/assert.sh
# shellcheck disable=SC1091
. tests/live/lib/live-lib.sh

export LIVE_FED_AUTH_INTERVAL=0
STATE="$(mktemp -d)"; trap 'rm -rf "$STATE"' EXIT

# try_after_n — Unauthorized ($N times), then accepted. Counts refreshes too.
try_after_n() { local c; c=$(( $(cat "$STATE/tries" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$STATE/tries"; [ "$c" -gt "$N" ] && return 0; return 10; }
try_never()   { return 10; }
try_broken()  { return 1; }
refresh_ok()  { echo $(( $(cat "$STATE/refresh" 2>/dev/null || echo 0) + 1 )) > "$STATE/refresh"; return 0; }
refresh_bad() { return 1; }
reset() { rm -f "$STATE/tries" "$STATE/refresh"; }

reset; N=3; out="$(LIVE_FED_AUTH_WAIT=60 fed_auth_wait try_after_n refresh_ok)"; rc=$?
assert_eq "lag then accepted: rc 0" 0 "$rc"
assert_eq "lag then accepted: tried 4 times" 4 "$(cat "$STATE/tries")"
assert_eq "lag then accepted: refreshed before each retry" 3 "$(cat "$STATE/refresh")"
assert_contains "lag then accepted: says why it waits" "not yet honouring the issuer" "$out"
assert_contains "lag then accepted: reports acceptance" "federated token accepted after" "$out"

reset; N=0; out="$(fed_auth_wait try_after_n refresh_ok)"; rc=$?
assert_eq "accepted at once: rc 0, no refresh" "0 0" "$rc $(cat "$STATE/refresh" 2>/dev/null || echo 0)"

reset; out="$(LIVE_FED_AUTH_WAIT=0 fed_auth_wait try_never refresh_ok)"; rc=$?
assert_eq "never accepted: rc 10 at the deadline" 10 "$rc"
assert_contains "never accepted: names the wait" "LIVE_FED_AUTH_WAIT=0" "$out"

reset; out="$(LIVE_FED_AUTH_WAIT=60 fed_auth_wait try_broken refresh_ok)"; rc=$?
assert_eq "real failure: stops at once with its code" 1 "$rc"
assert_eq "real failure: no refresh attempted" 0 "$(cat "$STATE/refresh" 2>/dev/null || echo 0)"

reset; N=5; out="$(LIVE_FED_AUTH_WAIT=60 fed_auth_wait try_after_n refresh_bad)"; rc=$?
assert_eq "refresh fails: rc 11" 11 "$rc"
assert_contains "refresh fails: says so" "could not renew" "$out"

# The check actually uses it, with both callbacks.
CHECK=tests/live/checks/instantiate/cognito-federation-live.sh
assert_contains "the federation check waits through fed_auth_wait" "fed_auth_wait whoami_try refresh_if_needed" "$(cat "$CHECK")"
assert_contains "the check renews tokens with the refresh grant" "grant_type=refresh_token" "$(cat "$CHECK")"

assert_summary
