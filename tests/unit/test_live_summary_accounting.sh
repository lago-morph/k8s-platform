#!/usr/bin/env bash
# Hermetic unit test for the LIVE orchestrator's SUMMARISER accounting (kp-lc5).
#
# The bug this locks out: on RUN_ID=build6-2220 tests/live/run.sh printed
#   "summary  pass=25 skip=3 fail=0 expect-full-violations=0 checks=28"
# while the block immediately above it listed FOUR expect-full violations, and
# run.sh exited 3. The exit code was honest; the counter was not. The CI live-
# verify pass criterion is "zero expect-full violations" — a counter that can
# read 0 while violations are printed is a gate that can read green while broken.
#
# The invariant asserted here, over every scenario:
#
#   expect-full-violations=<N> on the summary line
#     == every violation NAMED under the "EXPECT-FULL VIOLATION" header — the
#        git-declared kinds no passing check covered, plus the child checks that
#        exited 3 (tagged "(expect-full)")
#   AND  N > 0  <=>  orchestrator exit code == 3
#
# Driven through the LIVE_EXPECT_FULL / LIVE_CHECKS_ROOT / LIVE_SKIP_REGISTER
# test seams: no cluster, no AWS, no network.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

. tests/lib/assert.sh

RUN=tests/live/run.sh
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf 'profile_choice: {}\ndisable_all: {}\nskips: []\n' > "$TMP/REGISTER.yaml"

# mkcheck <tier> <name> <exit-code> [COVERS-kind] — write a stub check.
mkcheck() {
  local tier="$1" name="$2" rc="$3" covers="${4:-}"
  mkdir -p "$TMP/$tier"
  {
    echo '#!/usr/bin/env bash'
    [ -n "$covers" ] && echo "echo 'COVERS $covers'"
    echo "exit $rc"
  } > "$TMP/$tier/$name.sh"
  chmod +x "$TMP/$tier/$name.sh"
}

reset_checks() { rm -rf "$TMP"/{after,instantiate,negative}; }

OUT=""; RC=0
# run_suite <env-assignments...> — run the orchestrator, capture combined output
# (the summary banner is stdout, the violation block stderr) and the exit code.
run_suite() {
  set +e
  OUT="$(env "$@" LIVE_CHECKS_ROOT="$TMP" LIVE_SKIP_REGISTER="$TMP/REGISTER.yaml" \
           bash "$RUN" 2>&1)"
  RC=$?
  set -e
}

# ---- the three numbers the invariant relates -------------------------------

# counter — the value printed on the summary line.
counter() { printf '%s\n' "$OUT" | sed -n 's/.*expect-full-violations=\([0-9][0-9]*\).*/\1/p' | head -1; }

# listed_viols — every violation NAMED under the EXPECT-FULL VIOLATION header:
# the git-declared kinds no passing check covered, plus the child checks that
# exited 3 (tagged "(expect-full)"). The block stops at the FAILED-checks header,
# which reuses the same bullet form for hard failures.
listed_viols() {
  printf '%s\n' "$OUT" | awk '
    /EXPECT-FULL VIOLATION/ { inblock = 1; next }
    /FAILED checks:/        { inblock = 0 }
    inblock && /^ *- /      { n++ }
    END { print n + 0 }'
}

# child_viols — of those, the ones that are a child's own exit-3.
child_viols() { printf '%s\n' "$OUT" | grep -c '(expect-full)' || true; }

# assert_accounting <scenario> <expected-total>
assert_accounting() {
  local name="$1" want="$2"
  local c printed
  c="$(counter)"; printed="$(listed_viols)"
  assert_eq "$name: printed violations == $want" "$want" "$printed"
  assert_eq "$name: summary counter agrees with the printed block" "$printed" "${c:-<absent>}"
  if [ "$want" -gt 0 ]; then
    assert_eq "$name: violations > 0 => exit 3" 3 "$RC"
  else
    assert_eq "$name: zero violations => exit is not 3" "true" \
      "$([ "$RC" -ne 3 ] && echo true || echo false)"
  fi
}

echo "── summariser: clean pass (zero violations) ──────────────────"
reset_checks
mkcheck after a 0 "iam.aws.m.upbound.io/Role"
run_suite LIVE_EXPECT_FULL=iam.aws.m.upbound.io/Role
assert_eq "clean pass ⇒ exit 0" 0 "$RC"
assert_accounting "clean" 0

echo ""
echo "── summariser: ONE declared-but-unverified kind ──────────────"
reset_checks
mkcheck after a 0 "iam.aws.m.upbound.io/Role"
mkcheck after b 2 "rds.aws.m.upbound.io/Instance"   # skipped ⇒ covers nothing
run_suite LIVE_EXPECT_FULL="iam.aws.m.upbound.io/Role rds.aws.m.upbound.io/Instance"
assert_accounting "one-missing" 1

echo ""
echo "── summariser: the build6-2220 shape — FOUR listed kinds ─────"
# The reproduction: four git-declared kinds with no passing check, a healthy
# passing check alongside them, exit 3 — and a counter that read 0.
reset_checks
mkcheck after a 0 "iam.aws.m.upbound.io/Role"
run_suite LIVE_EXPECT_FULL="iam.aws.m.upbound.io/Role
ec2.aws.m.upbound.io/SecurityGroup
generators.external-secrets.io/Password
rds.aws.m.upbound.io/SubnetGroup
secretsmanager.aws.m.upbound.io/SecretVersion"
assert_eq "four unverified kinds ⇒ exit 3" 3 "$RC"
assert_accounting "build6-2220 shape" 4

echo ""
echo "── summariser: a child's OWN exit-3 counts once ──────────────"
reset_checks
mkcheck after a 0 "iam.aws.m.upbound.io/Role"
mkcheck after b 3
run_suite LIVE_EXPECT_FULL=iam.aws.m.upbound.io/Role
assert_accounting "child-exit-3" 1
assert_eq "child-exit-3: the child is named as an expect-full violation" 1 "$(child_viols)"

echo ""
echo "── summariser: both kinds — child exit-3 AND a missing kind ──"
reset_checks
mkcheck after a 0 "iam.aws.m.upbound.io/Role"
mkcheck after b 3
run_suite LIVE_EXPECT_FULL="iam.aws.m.upbound.io/Role rds.aws.m.upbound.io/Instance"
assert_accounting "child-exit-3 + missing kind" 2

echo ""
echo "── summariser: a hard FAIL alongside a violation still reads 3 ──"
reset_checks
mkcheck after a 0 "iam.aws.m.upbound.io/Role"
mkcheck after b 1
run_suite LIVE_EXPECT_FULL="iam.aws.m.upbound.io/Role rds.aws.m.upbound.io/Instance"
assert_accounting "hard-fail + missing kind" 1
assert_contains "the hard FAIL is still reported" "FAILED checks:" "$OUT"

assert_summary
