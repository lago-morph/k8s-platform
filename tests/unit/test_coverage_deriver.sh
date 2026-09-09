#!/usr/bin/env bash
# Unit tests for the coverage deriver (FINAL-PLAN §4.5).
#
# Guards the extractor<->oracle contract so the generated coverage set and the
# committed oracle can never silently drift (the round-2 draft shipped an oracle
# written version-stripped while the command emitted versions, which would have
# stuck the gate WARN-ONLY forever — round-3 k8s-expert C2). Also asserts:
#   - byte-identical: derive-coverage.sh output == expected-coverage.txt
#   - version-independence: a v1beta1->v1beta2 bump yields the SAME keys
#   - registry completeness (ENFORCE): every derived kind is registered, and no
#     registry entry is stale
#   - the WARN->enforce flip lint: once the byte-identical fixture passes, the
#     deriver's mode flag MUST be `enforce` (a green fixture with mode still
#     `warn` is itself a red diff — round-3 devx M4)
#   - defended_by coverage (WARN-ONLY until P2/P4): a `pending:*` marker prints a
#     WARN but does not fail.
#   - the EXPECT-FULL subset (kp-2al.20, ENFORCE): `--expect-full` is the derived
#     set minus the registry's `coverage: transitive` kinds; every transitive kind
#     must ride on a check that also defends a NON-transitive kind; and CI's
#     explicit LIVE_EXPECT_FULL must be a subset of it, so the two surfaces that
#     declare what the platform owes can never contradict each other.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

. tests/lib/assert.sh

DERIVE=tests/coverage/derive-coverage.sh
ORACLE=tests/coverage/expected-coverage.txt
REGISTRY=tests/coverage/registry.yaml
MODE_FILE=tests/coverage/mode
FIXDIR=tests/coverage/fixtures/version-bump

echo "── coverage: byte-identical extractor <-> oracle ─────────────"
derived="$("$DERIVE" 2>/dev/null)"
oracle="$(sort -u "$ORACLE")"
assert_eq "derived set == committed oracle (byte-identical)" "$oracle" "$derived"

# Record whether the byte-identical contract holds — it gates the flip lint.
fixture_green=false
[ "$derived" = "$oracle" ] && fixture_green=true

echo ""
echo "── coverage: version-independence (v1beta1 == v1beta2) ───────"
v1="$(COVERAGE_COMPOSITIONS_DIR="$FIXDIR" bash -c '
  yq ".spec.pipeline[]?.input.resources[]? | select(.base) | (.base.apiVersion | sub(\"/.*\";\"\")) + \"/\" + .base.kind" '"$FIXDIR"'/comp-v1beta1.yaml | sort -u')"
v2="$(yq '.spec.pipeline[]?.input.resources[]? | select(.base) | (.base.apiVersion | sub("/.*";"")) + "/" + .base.kind' "$FIXDIR/comp-v1beta2.yaml" | sort -u)"
assert_eq "v1beta1 keys == v1beta2 keys (version-stripped)" "$v1" "$v2"
assert_contains "fixture yields group/kind, no version" "iam.aws.m.upbound.io/Role" "$v1"
assert_eq "no version segment leaked into the key" "" "$(printf '%s\n' "$v1" | grep -E '/v[0-9]' || true)"

echo ""
echo "── coverage: registry completeness (ENFORCE) ─────────────────"
# Every derived kind must be a key under registry.yaml `kinds:`.
registered="$(yq -r '.kinds | keys | .[]' "$REGISTRY" | sort -u)"
missing="$(comm -23 <(printf '%s\n' "$derived") <(printf '%s\n' "$registered"))"
assert_eq "every derived kind is registered" "" "$missing"
# No stale registry entry (a key with no backing composition).
stale="$(comm -13 <(printf '%s\n' "$derived") <(printf '%s\n' "$registered"))"
assert_eq "no stale registry entry" "" "$stale"

echo ""
echo "── coverage: WARN->enforce flip lint (round-3 devx M4) ───────"
mode="$(tr -d '[:space:]' < "$MODE_FILE")"
if [ "$fixture_green" = "true" ]; then
  assert_eq "byte-identical fixture passes => mode must be 'enforce'" "enforce" "$mode"
else
  _pass "fixture not yet green => WARN-ONLY tolerated (mode=$mode)"
fi
# The drift gate itself must agree with the mode (exit 0 here since sets match).
"$DERIVE" --check >/dev/null 2>&1
assert_exit_code "derive --check passes on the committed tree" 0 "$DERIVE" --check

echo ""
echo "── coverage: defended_by coverage (WARN-ONLY until P2/P4) ────"
pending_count=0
while IFS= read -r k; do
  d="$(yq -r ".kinds.\"$k\".defended_by" "$REGISTRY")"
  case "$d" in
    pending:*) pending_count=$((pending_count+1)); echo "  WARN: $k defended_by=$d (behavioral test pending)" ;;
    null|"")   _fail "defended_by present for $k" "missing defended_by field" ;;
  esac
done <<< "$derived"
# Not a failure while behavioral phases are open; just report the count.
echo "  ($pending_count kind(s) awaiting a behavioral test — WARN, not FAIL)"
_pass "defended_by field present for every registered kind"

echo ""
echo "── coverage: EXPECT-FULL subset (kp-2al.20, ENFORCE) ─────────"
# The live orchestrator gates on `--expect-full`, NOT the bare derived set:
# coverage is counted at runtime from the COVERS lines checks emit, so a kind
# with no standalone check (registry `coverage: transitive`) would read
# "declared but unverified" forever (build6-2220: four such kinds => exit 3).
# NOTE: assert_exit_code above leaves errexit ON, so every capture below is
# `|| true`-guarded: a missing subcommand must read as a FAILED ASSERTION, not
# as an aborted test file.
transitive="$( { yq -r '.kinds | to_entries | map(select(.value.coverage == "transitive")) | .[].key' "$REGISTRY" || true; } | sed '/^$/d' | sort -u)"
expect_full="$( { "$DERIVE" --expect-full 2>/dev/null || true; } | sort -u)"
assert_eq "--expect-full emits a non-empty set" "true" \
  "$([ -n "$expect_full" ] && echo true || echo false)"
assert_eq "--expect-full == derived minus the transitive kinds" \
  "$(comm -23 <(printf '%s\n' "$derived") <(printf '%s\n' "$transitive"))" \
  "$expect_full"
# No transitive kind may leak back into the gated set.
leaked=""
while IFS= read -r k; do
  [ -z "$k" ] && continue
  printf '%s\n' "$expect_full" | grep -qxF "$k" && leaked="$leaked $k"
done <<< "$transitive"
assert_eq "no transitive kind is in the EXPECT-FULL set" "" "$leaked"
# The four kinds build6-2220 reported unverified are exactly the transitive ones.
for k in ec2.aws.m.upbound.io/SecurityGroup \
         generators.external-secrets.io/Password \
         rds.aws.m.upbound.io/SubnetGroup \
         secretsmanager.aws.m.upbound.io/SecretVersion; do
  assert_eq "build6-2220 kind excluded from EXPECT-FULL: $k" "true" \
    "$(printf '%s\n' "$expect_full" | grep -qxF "$k" && echo false || echo true)"
  assert_contains "still REGISTERED with a real defender: $k" \
    "tests/live/checks/" "$(yq -r ".kinds.\"$k\".defended_by" "$REGISTRY")"
done

echo ""
echo "── coverage: a transitive kind must RIDE on a gated check ────"
# A `coverage: transitive` kind is only honest if the check that defends it is
# itself gated — i.e. that check also defends a NON-transitive kind, which stays
# in EXPECT-FULL. Otherwise marking a kind transitive would orphan it entirely.
# kind|defended_by|coverage for every registry entry (yq v4 has no --arg).
pairs="$(yq -r '.kinds | to_entries | .[]
          | .key + "|" + (.value.defended_by // "") + "|" + (.value.coverage // "")' "$REGISTRY" || true)"
orphans=""
while IFS= read -r k; do
  [ -z "$k" ] && continue
  d="$(printf '%s\n' "$pairs" | awk -F'|' -v k="$k" '$1 == k { print $2 }')"
  riders="$(printf '%s\n' "$pairs" | awk -F'|' -v d="$d" '$2 == d && $3 != "transitive"' | grep -c . || true)"
  [ "${riders:-0}" -gt 0 ] || orphans="$orphans $k"
done <<< "$transitive"
assert_eq "every transitive kind rides on a check that also defends a gated kind" "" "$orphans"

echo ""
echo "── coverage: CI's LIVE_EXPECT_FULL ⊆ derived EXPECT-FULL ─────"
# The two surfaces that declare what the platform owes must not contradict each
# other (kp-2al.20): CI may declare FEWER kinds than the derivation (a CI runner
# cannot reach the SSM relay, so kubectl-driven checks SKIP there), but it must
# never declare a kind the registry records as transitively covered — that kind
# has no check that can ever emit its COVERS line.
CI_PRODUCER=".github/scripts/live-verify-run.sh"
ci_list="$( { sed -n '/^export LIVE_EXPECT_FULL="/,/"$/p' "$CI_PRODUCER" || true; } \
            | sed 's/^export LIVE_EXPECT_FULL="//; s/"$//' | sed '/^$/d' | sort -u)"
assert_eq "CI declares a non-empty LIVE_EXPECT_FULL" "true" \
  "$([ -n "$ci_list" ] && echo true || echo false)"
assert_eq "every CI-declared kind is in the derived EXPECT-FULL set" "" \
  "$(comm -23 <(printf '%s\n' "$ci_list") <(printf '%s\n' "$expect_full"))"

assert_summary
