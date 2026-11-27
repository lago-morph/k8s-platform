#!/usr/bin/env bash
# kp-2al.37 / kp-zab.6 — relay hygiene for EVERY live check (audit-before-enforce:
# scans all of tests/live/checks, not just the files that motivated it).
#
#  1. A check that drives the relay helper declares `# live-identity: cluster`,
#     so the orchestrator runs it under an identity that CAN open the relay.
#     (Without it, CI ran 12 checks as the scoped role and they all skipped.)
#  2. No relay `--exec` call discards its stderr (2>/dev/null): that stderr is
#     the only place the real failure reason appears; discarding it is how a
#     permission denial was reported as a "tunnel flake" on builds #9 and #10.
#  3. relay_denied_skip / relay_err_tail behave on fixture stderr.
set -uo pipefail
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
. tests/lib/assert.sh

CHECKS="tests/live/checks"
n_relay=0
for f in "$CHECKS"/*/*.sh; do
  id="${f#"$CHECKS"/}"
  if grep -qE '"\$HELPER"[^#]*--exec|\$HELPER" -c' "$f"; then
    n_relay=$((n_relay+1))
    grep -qE '^# live-identity: cluster' "$f" \
      && _pass "declares cluster identity: $id" \
      || _fail "declares cluster identity: $id" "drives the relay helper but has no '# live-identity: cluster' header"
  fi
  # Join continuation lines so a multi-line helper call is one logical line.
  bad="$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$f" | grep -E -- '--exec' | grep -E '2>/dev/null' || true)"
  [ -z "$bad" ] \
    && _pass "relay stderr captured: $id" \
    || _fail "relay stderr captured: $id" "a --exec call discards stderr: $(printf '%s' "$bad" | head -1 | cut -c1-120)"
done
assert_eq "relay-driving checks found (scan is not vacuous)" "true" \
  "$([ "$n_relay" -ge 10 ] && echo true || echo false)"
echo "  ($n_relay checks drive the relay helper)"

# ---- 3. lib helpers -------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/denied.sh" <<'SH'
. tests/live/lib/live-lib.sh
f="$(mktemp)"
echo "An error occurred (AccessDeniedException) when calling the StartSession operation: User: arn:aws:sts::1:assumed-role/x/y is not authorized to perform: ssm:StartSession on resource: arn:aws:ec2:us-east-1:1:instance/i-1" > "$f"
relay_denied_skip "$f"
echo "NOT-SKIPPED"
SH
out="$(bash "$TMP/denied.sh" 2>&1)"; rc=$?
assert_eq "denied stderr ⇒ skip exit code 2" 2 "$rc"
assert_contains "denied ⇒ says the caller lacks relay access" "cannot ssm:StartSession" "$out"
assert_contains "denied ⇒ never calls it a tunnel flake" "not a tunnel flake" "$out"
assert_contains "denied ⇒ shows the helper's stderr" "relay helper stderr (last 5 lines)" "$out"

cat > "$TMP/other.sh" <<'SH'
. tests/live/lib/live-lib.sh
f="$(mktemp)"; echo "FATAL: SSM tunnel did not open. Log: connection reset" > "$f"
relay_denied_skip "$f"
echo "NOT-SKIPPED"
relay_err_tail "$f"
e="$(mktemp)"; relay_err_tail "$e"
SH
out="$(bash "$TMP/other.sh" 2>&1)"; rc=$?
assert_eq "non-permission stderr ⇒ no skip (retry continues)" 0 "$rc"
assert_contains "non-permission ⇒ continues" "NOT-SKIPPED" "$out"
assert_contains "err tail prints the helper's last line" "| FATAL: SSM tunnel did not open" "$out"
assert_contains "empty stderr is stated, not silent" "relay helper stderr: (empty)" "$out"

assert_summary
