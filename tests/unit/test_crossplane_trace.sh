#!/usr/bin/env bash
# Unit tests for scripts/crossplane-trace.sh.
#
# Spec: ai/brainstorming/specs/SPEC-S2-crossplane-trace.md
#
# Strategy: replace kubectl and aws with shims that dispatch on argv to
# canned fixture files under tests/unit/fixtures/crossplane-trace/. The
# script-under-test is invoked with KUBECTL=<shim> AWS_REGION=us-east-1 and
# a mocked aws binary on PATH; no real cluster or AWS account is contacted.
#
# Contracts defended (spec §6 + adversarial-review additions inline):
#   1. --help prints --watch and --json (§11 item 2)
#   2. happy-path fixture: human output starts with "=== CROSSPLANE TRACE:"
#      and ends "=== END TRACE ===" (§6 contract a)
#   3. happy-path output ≤ 5120 bytes (§6 contract b)
#   4. SA-mismatch fixture: exactly one MISMATCH (§6 contract c, §11 item 7)
#   5. xr-empty-conditions fixture: contains "<empty" (§6 contract d)
#   6. mr-access-denied fixture: contains "[FAIL]" (§6 contract e)
#   7. --json emits valid JSON with all five top-level keys (§6, §11)
#   8. Ready=True fixture + --watch → exits 0 (§6 watch contract)
#   9. not-ready + --timeout 0 + --watch → exits 2 within 1 s (§11 item 5)
#  10. lookup-failed root: exit !=0, prints "ROOT: lookup-failed" (§11 item 3)
#  11. lookup-failed claim + --json: exit !=0, jq parses (§11 item 4)
#  12. 12-resourceRefs + 5-failing-MRs output ≤ 5120 bytes (§11 item 6)
#  13. bash -n syntax check
#  14. SKIP_AWS=1 path emits no MATCH/MISMATCH (defends region-guard)
#  15. shellcheck clean (skipped if shellcheck absent)
#  16. case-insensitive kind handling (spec §5.1)
#  17. kp-2al.28: a Crossplane v2 composite (no claim layer, machinery under
#      .spec.crossplane) has EVERY composed resource listed by name, and the
#      composition reference read. Asserts on CONTENT, because the bug was a
#      silent empty trace that exited 0 and looked clean.
#  18. the v2 fixture stays equal to the committed render fixture it came from
#  19. kp-2al.32: the provider POD is found when its label carries the full
#      provider name (the old selector stripped "upbound-" and matched nothing,
#      so the trace printed "pod: ?" beside a Healthy Provider)
#  20. kp-2al.32: with no matching pod at all, the ServiceAccount still
#      resolves through the Provider's DeploymentRuntimeConfig, and no foreign
#      pod's SA is ever reported in its place

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

FIXTURES="tests/unit/fixtures/crossplane-trace"
SCRIPT="scripts/crossplane-trace.sh"

# ---------------------------------------------------------------------------
# Mock kubectl shim
# ---------------------------------------------------------------------------
# Dispatches on `get <kind>/<name>` (and the kind alone for list calls).
# Reads $MOCK_MAP — a colon-separated list of "<lowercase-kind>/<name>=<fixture>"
# entries — to decide what to print. A `*=<fixture>` entry is a fall-through.
# Missing entry → exit 1 (simulates "NotFound").
# `kubectl get pods -l ...` returns $MOCK_POD_FIXTURE.
# `kubectl get sa <name> -n <ns>` returns $MOCK_SA_FIXTURE.
# `kubectl get provider.pkg.crossplane.io <name>` returns $MOCK_PROVIDER_FIXTURE.

MOCK_DIR="$(mktemp -d -t cptrace-mock-XXXXXX)"
trap 'rm -rf "$MOCK_DIR"' EXIT

cat > "$MOCK_DIR/kubectl" <<'SHIM'
#!/usr/bin/env bash
# Mock kubectl for test_crossplane_trace.sh
set -u

LOG="${MOCK_ARGS_LOG:-/dev/null}"
echo "$*" >> "$LOG"

# Parse argv
verb=""; kind_name=""; name=""; ns=""; output=""; selector=""
get_kind=""
i=0
args=("$@")
while [[ $i -lt ${#args[@]} ]]; do
  a="${args[$i]}"
  case "$a" in
    get) verb="get" ;;
    -n) i=$((i+1)); ns="${args[$i]:-}" ;;
    -o) i=$((i+1)); output="${args[$i]:-}" ;;
    -l) i=$((i+1)); selector="${args[$i]:-}" ;;
    -A|--all-namespaces) ns="__ALL__" ;;
    *)
      if [[ "$verb" == "get" && -z "$kind_name" ]]; then
        kind_name="$a"
      fi
      ;;
  esac
  i=$((i+1))
done

# kind_name may be "kind/name" or just "kind"
if [[ "$kind_name" == */* ]]; then
  kind="${kind_name%%/*}"
  name="${kind_name#*/}"
else
  kind="$kind_name"
  name=""
fi
kind_lc=$(echo "$kind" | tr '[:upper:]' '[:lower:]')

# Resolve fixture
fixture=""
IFS=':' read -ra entries <<< "${MOCK_MAP:-}"
for e in "${entries[@]}"; do
  key="${e%%=*}"
  val="${e#*=}"
  if [[ "$key" == "$kind_lc/$name" ]]; then
    fixture="$val"; break
  fi
done
if [[ -z "$fixture" ]]; then
  for e in "${entries[@]}"; do
    key="${e%%=*}"
    val="${e#*=}"
    if [[ "$key" == "$kind_lc/*" ]]; then
      fixture="$val"; break
    fi
  done
fi

# Special: kubectl get pods -n crossplane-system -l ...
# MOCK_POD_LABEL, when set, is the label the fake cluster ACTUALLY carries: a
# -l selector that does not equal it returns an empty item list, the way a real
# cluster answers a selector that matches nothing. Without this the shim hands
# back the pod fixture for any selector at all, which is precisely what let the
# kp-2al.32 selector bug pass the suite.
if [[ "$kind_lc" == "pods" || "$kind_lc" == "pod" ]]; then
  fixture="${MOCK_POD_FIXTURE:-}"
  if [[ -n "${MOCK_POD_LABEL:-}" && -n "$selector" && "$selector" != "${MOCK_POD_LABEL}" ]]; then
    echo '{"items":[]}'
    exit 0
  fi
fi
# Special: kubectl get deploymentruntimeconfig <name>
if [[ "$kind_lc" == deploymentruntimeconfig* ]]; then
  fixture="${MOCK_DRC_FIXTURE:-}"
fi
# Special: kubectl get sa/<name> ...
if [[ "$kind_lc" == "sa" || "$kind_lc" == "serviceaccount" || "$kind_lc" == "serviceaccounts" ]]; then
  fixture="${MOCK_SA_FIXTURE:-}"
fi
# Special: kubectl get provider.pkg ...
if [[ "$kind_lc" == "provider"* || "$kind_lc" == "providers"* ]]; then
  fixture="${MOCK_PROVIDER_FIXTURE:-}"
fi

if [[ -z "$fixture" || ! -f "$fixture" ]]; then
  echo "Error from server (NotFound): $kind \"$name\" not found" >&2
  exit 1
fi

# If output is jsonpath, extract just the requested field (best-effort).
if [[ "$output" == jsonpath=* ]]; then
  jp="${output#jsonpath=}"
  case "$jp" in
    *'@.type=="Ready"'*)
      python3 -c '
import json, sys
with open(sys.argv[1]) as f: d=json.load(f)
for c in (d.get("status") or {}).get("conditions") or []:
    if c.get("type")=="Ready":
        sys.stdout.write(c.get("status","")); break
' "$fixture"
      exit 0 ;;
    *'@.type=="Synced"'*)
      python3 -c '
import json, sys
with open(sys.argv[1]) as f: d=json.load(f)
for c in (d.get("status") or {}).get("conditions") or []:
    if c.get("type")=="Synced":
        sys.stdout.write(c.get("status","")); break
' "$fixture"
      exit 0 ;;
    *)
      # Best-effort: empty
      exit 0 ;;
  esac
fi

cat "$fixture"
exit 0
SHIM
chmod +x "$MOCK_DIR/kubectl"

# ---------------------------------------------------------------------------
# Mock aws shim
# ---------------------------------------------------------------------------
cat > "$MOCK_DIR/aws" <<'AWS'
#!/usr/bin/env bash
# Mock aws CLI for test_crossplane_trace.sh
set -u
LOG="${MOCK_AWS_LOG:-/dev/null}"
echo "$*" >> "$LOG"

# Detect command
cmd=""
sub=""
for a in "$@"; do
  case "$a" in
    sts|iam|s3|ec2|eks) cmd="$a" ;;
    get-caller-identity|get-role) sub="$a" ;;
  esac
done

if [[ "$cmd" == "sts" && "$sub" == "get-caller-identity" ]]; then
  echo "123456789012"
  exit 0
fi

if [[ "$cmd" == "iam" && "$sub" == "get-role" ]]; then
  # Emit a trust policy that names the SA from $MOCK_TRUST_SA (or a default)
  trust_sa="${MOCK_TRUST_SA:-upbound-provider-family-aws}"
  trust_ns="${MOCK_TRUST_NS:-crossplane-system}"
  cat <<JSON
{
  "Role": {
    "RoleName": "k8-platform-mgmt-crossplane",
    "Arn": "arn:aws:iam::123456789012:role/k8-platform-mgmt-crossplane",
    "AssumeRolePolicyDocument": {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {"Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/XXXXX"},
          "Action": "sts:AssumeRoleWithWebIdentity",
          "Condition": {
            "StringEquals": {
              "oidc.eks.us-east-1.amazonaws.com/id/XXXXX:sub": "system:serviceaccount:${trust_ns}:${trust_sa}"
            }
          }
        }
      ]
    }
  }
}
JSON
  exit 0
fi

# Default
exit 0
AWS
chmod +x "$MOCK_DIR/aws"

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
# run_script <map> [env-vars] -- <argv>
run_script() {
  local map="$1"; shift
  local pod_fixture="" sa_fixture="" provider_fixture="" trust_sa="" skip_aws=""
  local pod_label="" drc_fixture=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pod) pod_fixture="$2"; shift 2 ;;
      --sa)  sa_fixture="$2"; shift 2 ;;
      --provider) provider_fixture="$2"; shift 2 ;;
      --trust-sa) trust_sa="$2"; shift 2 ;;
      --skip-aws) skip_aws=1; shift ;;
      --pod-label) pod_label="$2"; shift 2 ;;
      --drc) drc_fixture="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  local args_log aws_log
  args_log=$(mktemp -p "$MOCK_DIR" args.XXXXXX)
  aws_log=$(mktemp -p "$MOCK_DIR" aws.XXXXXX)
  # `env` and not a bare assignment prefix: a ${var:+NAME=1} expansion is not
  # recognised as an assignment, so --skip-aws used to run "SKIP_AWS_OVERRIDE=1"
  # as a command and the script never started.
  local -a envv=(
    "MOCK_MAP=$map"
    "MOCK_POD_FIXTURE=$pod_fixture"
    "MOCK_SA_FIXTURE=$sa_fixture"
    "MOCK_PROVIDER_FIXTURE=$provider_fixture"
    "MOCK_TRUST_SA=$trust_sa"
    "MOCK_POD_LABEL=$pod_label"
    "MOCK_DRC_FIXTURE=$drc_fixture"
    "MOCK_ARGS_LOG=$args_log"
    "MOCK_AWS_LOG=$aws_log"
    "KUBECTL=$MOCK_DIR/kubectl"
    "PATH=$MOCK_DIR:$PATH"
    "AWS_REGION=us-east-1"
  )
  [[ -n "$skip_aws" ]] && envv+=("SKIP_AWS_OVERRIDE=1")
  env "${envv[@]}" bash "$SCRIPT" "$@"
  local rc=$?
  LAST_ARGS_LOG="$args_log"
  LAST_AWS_LOG="$aws_log"
  return $rc
}

# ===========================================================================
# Test 1: --help prints --watch and --json
# ===========================================================================
echo "── test 1: --help mentions --watch and --json ──"
help_out=$(bash "$SCRIPT" --help 2>&1)
rc=$?
assert_eq "help_exit_0" "0" "$rc"
assert_contains "help_has_watch" "--watch" "$help_out"
assert_contains "help_has_json"  "--json"  "$help_out"

# ===========================================================================
# Test 2: happy-path output framing + budget
# ===========================================================================
echo "── test 2: happy-path framing + budget ──"
MAP_OK="platformsecret/happy-claim=$FIXTURES/claim-ok.json:xplatformsecret/happy-claim-xr1=$FIXTURES/xr-ok.json:secret/happy-claim-asm=$FIXTURES/mr-ok.json"
set +e
out=$(run_script "$MAP_OK" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/happy-claim -n default 2>&1)
rc=$?
set -e
assert_contains "happy_starts_marker" "=== CROSSPLANE TRACE:" "$out"
assert_contains "happy_ends_marker"   "=== END TRACE ==="     "$out"
bytes=${#out}
if [[ "$bytes" -le 5120 ]]; then
  _pass "happy_under_5kb"
else
  _fail "happy_under_5kb" "size $bytes > 5120"
fi

# ===========================================================================
# Test 3: SA mismatch — exactly one MISMATCH
# ===========================================================================
echo "── test 3: SA-mismatch fixture produces MISMATCH ──"
MAP_MM="platformsecret/stuck-claim=$FIXTURES/claim-failing.json:xplatformsecret/stuck-claim-xr1=$FIXTURES/xr-with-mrs.json:secret/stuck-claim-asm=$FIXTURES/mr-access-denied.json"
set +e
out=$(run_script "$MAP_MM" \
        --pod "$FIXTURES/provider-pod-sa-mismatch.json" \
        --sa  "$FIXTURES/provider-sa-mismatch.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/stuck-claim -n default 2>&1)
set -e
mm_count=$(printf '%s\n' "$out" | grep -c MISMATCH || true)
assert_eq "sa_mismatch_exactly_one" "1" "$mm_count"
assert_contains "sa_mismatch_pod_sa_line" "pod-SA:" "$out"

# ===========================================================================
# Test 4: XR empty conditions → "<empty"
# ===========================================================================
echo "── test 4: xr-empty-conditions emits <empty marker ──"
MAP_EMPTY="platformsecret/stuck-claim=$FIXTURES/claim-failing.json:xplatformsecret/stuck-claim-xr1=$FIXTURES/xr-empty-conditions.json"
set +e
out=$(run_script "$MAP_EMPTY" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        -- PlatformSecret/stuck-claim -n default 2>&1)
set -e
assert_contains "xr_empty_marker" "<empty" "$out"

# ===========================================================================
# Test 5: MR access-denied → [FAIL]
# ===========================================================================
echo "── test 5: mr-access-denied fixture produces [FAIL] ──"
MAP_AD="platformsecret/stuck-claim=$FIXTURES/claim-failing.json:xplatformsecret/stuck-claim-xr1=$FIXTURES/xr-with-mrs.json:secret/stuck-claim-asm=$FIXTURES/mr-access-denied.json"
set +e
out=$(run_script "$MAP_AD" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/stuck-claim -n default 2>&1)
set -e
assert_contains "mr_fail_marker" "[FAIL]" "$out"

# ===========================================================================
# Test 6: --json emits valid JSON with five top-level keys
# ===========================================================================
echo "── test 6: --json mode ──"
set +e
json_out=$(run_script "$MAP_OK" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/happy-claim -n default --json 2>/dev/null)
rc=$?
set -e
assert_eq "json_exit_0" "0" "$rc"
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$json_out" | jq . >/dev/null 2>&1; then
    _pass "json_is_valid"
  else
    _fail "json_is_valid" "jq could not parse output"
  fi
  for k in timestamp claim xr managedResources provider irsa; do
    if printf '%s' "$json_out" | jq -e ".$k" >/dev/null 2>&1; then
      _pass "json_has_$k"
    else
      _fail "json_has_$k" "key missing"
    fi
  done
else
  echo "  (jq not installed — skipping JSON content asserts)"
fi

# ===========================================================================
# Test 7: --watch on Ready=True exits 0 within first cycle
# ===========================================================================
echo "── test 7: --watch + Ready=True → exit 0 ──"
set +e
out=$(TRACE_INTERVAL=1 run_script "$MAP_OK" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/happy-claim -n default --watch --timeout 30 2>&1)
rc=$?
set -e
assert_eq "watch_ready_exit_0" "0" "$rc"
assert_contains "watch_ready_marker" "watch exiting 0" "$out"

# ===========================================================================
# Test 8: --watch + --timeout 0 + not-ready → exit 2 within 1 s
# ===========================================================================
echo "── test 8: --watch + --timeout 0 + not-ready → exit 2 ──"
MAP_NR="platformsecret/stuck-claim=$FIXTURES/claim-failing.json:xplatformsecret/stuck-claim-xr1=$FIXTURES/xr-with-mrs.json:secret/stuck-claim-asm=$FIXTURES/mr-access-denied.json"
set +e
t0=$(date +%s)
out=$(TRACE_INTERVAL=1 run_script "$MAP_NR" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/stuck-claim -n default --watch --timeout 0 2>&1)
rc=$?
t1=$(date +%s)
set -e
elapsed=$((t1 - t0))
assert_eq "watch_timeout0_exit_2" "2" "$rc"
if [[ "$elapsed" -le 3 ]]; then
  _pass "watch_timeout0_under_3s"
else
  _fail "watch_timeout0_under_3s" "elapsed ${elapsed}s"
fi
assert_contains "watch_timeout_marker" "TIMEOUT" "$out"

# ===========================================================================
# Test 9: lookup-failed claim → non-zero exit + CLAIM: lookup-failed marker
# ===========================================================================
echo "── test 9: lookup-failed claim → non-zero exit + marker ──"
set +e
out=$(run_script "" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/nonexistent -n default 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  _pass "lookup_failed_nonzero_exit"
else
  _fail "lookup_failed_nonzero_exit" "got rc=0"
fi
assert_contains "lookup_failed_marker" "ROOT: lookup-failed" "$out"

# ===========================================================================
# Test 10: lookup-failed + --json → non-zero exit + jq parses
# ===========================================================================
echo "── test 10: lookup-failed + --json → jq-parseable ──"
set +e
json_out=$(run_script "" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/nonexistent -n default --json 2>/dev/null)
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  _pass "lookup_failed_json_nonzero_exit"
else
  _fail "lookup_failed_json_nonzero_exit" "got rc=0"
fi
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$json_out" | jq . >/dev/null 2>&1; then
    _pass "lookup_failed_json_valid"
  else
    _fail "lookup_failed_json_valid" "jq could not parse"
  fi
fi

# ===========================================================================
# Test 11: 12-resourceRefs fixture stays within 5 KB budget
# ===========================================================================
echo "── test 11: big-fan-out output ≤ 5120 bytes ──"
MAP_BIG="platformsecret/big-claim=$FIXTURES/claim-failing.json:xplatformsecret/stuck-claim-xr1=$FIXTURES/xr-12-refs.json"
# All 12 MRs map to the long failing fixture
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
  MAP_BIG="$MAP_BIG:secret/mr$i=$FIXTURES/mr-failing-long.json"
done
set +e
out=$(run_script "$MAP_BIG" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/big-claim -n default 2>&1)
set -e
bytes=${#out}
if [[ "$bytes" -le 5120 ]]; then
  _pass "big_fanout_under_5kb"
else
  _fail "big_fanout_under_5kb" "size $bytes > 5120"
fi

# ===========================================================================
# Test 12: bash -n syntax check
# ===========================================================================
echo "── test 12: bash -n syntax check ──"
if bash -n "$SCRIPT" 2>/dev/null; then
  _pass "syntax_clean"
else
  _fail "syntax_clean" "bash -n failed"
fi

# ===========================================================================
# Test 13: SKIP_AWS env path emits no MATCH/MISMATCH
# ===========================================================================
echo "── test 13: SKIP_AWS path omits MATCH/MISMATCH ──"
set +e
out=$(AWS_REGION=eu-west-1 run_script "$MAP_OK" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- PlatformSecret/happy-claim -n default 2>&1)
set -e
if printf '%s\n' "$out" | grep -qE 'MATCH|MISMATCH'; then
  _fail "skip_aws_no_match_lines" "found MATCH/MISMATCH despite SKIP_AWS region"
else
  _pass "skip_aws_no_match_lines"
fi

# ===========================================================================
# Test 14: case-insensitive kind handling
# ===========================================================================
echo "── test 14: kind is case-insensitive ──"
set +e
out=$(run_script "$MAP_OK" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --provider "$FIXTURES/provider-pkg.json" \
        --trust-sa "upbound-provider-family-aws" \
        -- platformsecret/happy-claim -n default 2>&1)
rc=$?
set -e
assert_contains "lowercase_kind_works" "=== END TRACE ===" "$out"

# ===========================================================================
# Test 15: shellcheck clean (skipped if absent)
# ===========================================================================
echo "── test 15: shellcheck ──"
if command -v shellcheck >/dev/null 2>&1; then
  # -x so shellcheck follows the optional `_lib/k8s-helpers.sh` source
  # (resolved via the SCRIPTDIR directive in scripts/crossplane-trace.sh).
  if shellcheck -x "$SCRIPT" 2>&1; then
    _pass "shellcheck_clean"
  else
    _fail "shellcheck_clean" "shellcheck reported issues"
  fi
else
  echo "  (shellcheck not installed — skipping)"
fi

# ===========================================================================
# Test 16 (kp-2al.28): Crossplane v2 composite — every composed resource listed
# ===========================================================================
# Regression: the script read .spec.resourceRefs (v1) on an object whose refs
# live at .spec.crossplane.resourceRefs (v2), so MR_REFS_JSON stayed "[]", the
# iteration body never ran, and the trace printed the composite's own
# conditions and "=== END TRACE ===" with none of its 16 managed resources —
# exit 0, clean-looking, useless. Confirmed live 2026-09-10 on build #7's
# XPlatformCluster platform/platform. The assertions below are on CONTENT:
# exit status and framing never caught this and never will.
echo "── test 16: v2 composite lists every composed resource ──"
V2_FIXTURE="$FIXTURES/xr-v2-composite.json"
# One composed resource resolves to a real MR fixture; the rest resolve to
# NotFound, which is still a listing — the contract is that they appear at all.
MAP_V2="xplatformcluster/platform=$V2_FIXTURE:cluster/render-probe-cluster-69f9d71223c3=$FIXTURES/mr-ok.json"
set +e
out=$(run_script "$MAP_V2" \
        --provider "$FIXTURES/provider-pkg.json" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --skip-aws \
        -- XPlatformCluster/platform -n platform 2>&1)
rc=$?
set -e
assert_eq "v2_exit_0" "0" "$rc"
assert_contains "v2_ends_marker" "=== END TRACE ===" "$out"

# The composition reference lives at .spec.crossplane.compositionRef in v2;
# reading the v1 path printed "compRef=-" on a composite that had one.
assert_contains "v2_comp_ref_read" "compRef=platform-cluster" "$out"

# The count the operator is told about must be the real one.
v2_total=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(len(d["spec"]["crossplane"]["resourceRefs"]))' "$V2_FIXTURE")
assert_contains "v2_ref_count_reported" "resourceRefs ($v2_total total)" "$out"

# The human renderer budgets its output (12 refs walked, at most 5 failing
# ones printed in full), so the every-resource contract is asserted on --json,
# which is the machine-readable form and the one an agent reads back. This is
# the assertion the bug would have failed: managedResources was [] .
v2_shown=12
[[ "$v2_total" -lt "$v2_shown" ]] && v2_shown="$v2_total"
if [[ "$v2_total" -gt "$v2_shown" ]]; then
  assert_contains "v2_remainder_reported" "(+$((v2_total - v2_shown)) more)" "$out"
fi

set +e
v2_json=$(run_script "$MAP_V2" \
        --provider "$FIXTURES/provider-pkg.json" \
        --pod "$FIXTURES/provider-pod-ok.json" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --skip-aws \
        -- XPlatformCluster/platform -n platform --json 2>/dev/null)
set -e
v2_named=$(printf '%s' "$v2_json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(json.dumps(sorted(m["name"] for m in d["managedResources"])))' 2>/dev/null)
v2_want=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
refs=d["spec"]["crossplane"]["resourceRefs"][:int(sys.argv[2])]
print(json.dumps(sorted(r["name"] for r in refs)))' "$V2_FIXTURE" "$v2_shown")
assert_eq "v2_every_walked_ref_traced" "$v2_want" "$v2_named"

# The composed resource that does resolve must carry real condition content,
# not just a name: "listed but every entry lookup-failed" is the same silence.
v2_ok=$(printf '%s' "$v2_json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(sum(1 for m in d["managedResources"] if m["fail"]==0 and m["synced"]=="True"))' 2>/dev/null)
assert_eq "v2_resolved_mr_has_conditions" "1" "$v2_ok"

# v1 vocabulary is banned (AGENTS) and actively wrong here: there is no claim.
case "$out" in
  *CLAIM*) _fail "v2_no_claim_vocabulary" "output still labels the composite CLAIM" ;;
  *) _pass "v2_no_claim_vocabulary" ;;
esac

# ===========================================================================
# Test 17: the v2 fixture is the committed render output, not hand-drift
# ===========================================================================
echo "── test 17: v2 fixture refs match the render fixture ──"
RENDER_FIXTURE="crossplane/xrds/platform-cluster/render-fixtures/expected.yaml"
if command -v yq >/dev/null 2>&1; then
  a=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(json.dumps(sorted((r["kind"], r["apiVersion"]) for r in d["spec"]["crossplane"]["resourceRefs"])))' "$V2_FIXTURE")
  b=$(yq eval-all -o=json 'select(.kind=="XPlatformCluster") | .spec.crossplane.resourceRefs' "$RENDER_FIXTURE" \
      | python3 -c '
import json,sys
print(json.dumps(sorted((r["kind"], r["apiVersion"]) for r in json.load(sys.stdin))))')
  assert_eq "v2_fixture_matches_render_fixture" "$a" "$b"
else
  echo "  (yq not installed — skipping)"
fi

# ===========================================================================
# Test 19 (kp-2al.32): the provider pod is found by its real label
# ===========================================================================
# terraform recorded in 2026-06-05 (OI-2026-06-05-4) that the family-provider
# Deployment is NOT labelled pkg.crossplane.io/provider=provider-family-aws.
# The script selected on exactly that, so it matched nothing and reported
# "pod: ?" / "pod-SA: ?" next to a Provider it had just read as Healthy — which
# also disables the IRSA MATCH/MISMATCH check the script exists for.
echo "── test 19: provider pod found by its real label ──"
# One composed resource must RESOLVE and be un-Ready, because the provider is
# classified from the apiVersion of a managed resource the script actually
# read: if every MR lookup fails there is nothing to classify, so no provider
# layer is attempted at all.
MAP_P="xplatformcluster/platform=$FIXTURES/xr-v2-composite.json:certificatevalidation/render-probe-cluster-88b4ceffbc75=$FIXTURES/mr-access-denied.json"
set +e
out=$(run_script "$MAP_P" \
        --provider "$FIXTURES/provider-pkg-runtimeconfig.json" \
        --pod "$FIXTURES/provider-pod-family.json" \
        --pod-label "pkg.crossplane.io/provider=upbound-provider-family-aws" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --drc "$FIXTURES/provider-drc.json" \
        --skip-aws \
        -- XPlatformCluster/platform -n platform 2>&1)
set -e
assert_contains "pod_named_not_question_mark" "upbound-provider-family-aws-7d9f6c4b2-x8k2p" "$out"
assert_contains "pod_phase_read"              "phase=Running" "$out"
assert_contains "pod_sa_read"                 "pod-SA: upbound-provider-family-aws" "$out"
case "$out" in
  *"pod:    ?"*) _fail "pod_not_reported_unknown" "still prints 'pod: ?' for a labelled provider pod" ;;
  *) _pass "pod_not_reported_unknown" ;;
esac

# ===========================================================================
# Test 20 (kp-2al.32): no pod at all → SA still resolves, and never a stranger's
# ===========================================================================
# This platform pins the provider SA name in a DeploymentRuntimeConfig so the
# IRSA trust subject matches (terraform/management/helm.tf), so the SA is
# knowable even when the pod lookup fails. The old fallback listed every pod in
# crossplane-system and took items[0] — which can hand back the crossplane CORE
# pod's SA and turn IRSA into a confident MISMATCH about the wrong workload.
echo "── test 20: SA resolves via DeploymentRuntimeConfig with no pod ──"
set +e
out=$(run_script "$MAP_P" \
        --provider "$FIXTURES/provider-pkg-runtimeconfig.json" \
        --pod "$FIXTURES/provider-pod-core-only.json" \
        --pod-label "pkg.crossplane.io/provider=SOMETHING-ELSE" \
        --sa  "$FIXTURES/provider-sa-ok.json" \
        --drc "$FIXTURES/provider-drc.json" \
        --skip-aws \
        -- XPlatformCluster/platform -n platform 2>&1)
set -e
assert_contains "sa_from_runtimeconfig" "pod-SA: upbound-provider-family-aws" "$out"
# The namespace here holds only the crossplane CORE pods. Reporting the core
# pod's SA would be a confident wrong answer — worse than the '?' this bead
# started from, because it turns IRSA into a MISMATCH about the wrong workload.
foreign=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
items=d.get("items",[])
print(items[0]["spec"].get("serviceAccountName","") if items else "")' "$FIXTURES/provider-pod-core-only.json" 2>/dev/null)
if [[ -n "$foreign" && "$foreign" != "upbound-provider-family-aws" ]]; then
  case "$out" in
    *"pod-SA: $foreign"*) _fail "no_foreign_sa_reported" "reported an unrelated pod's SA ($foreign)" ;;
    *) _pass "no_foreign_sa_reported" ;;
  esac
else
  _pass "no_foreign_sa_reported (fixture SA not distinguishable — vacuous)"
fi

assert_summary
