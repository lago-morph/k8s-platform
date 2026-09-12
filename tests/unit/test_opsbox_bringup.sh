#!/usr/bin/env bash
# kp-2al.34 — the ops-box bring-up scripts.
#
# These scripts decide, on the operator's behalf, whether each stage of a
# bring-up is green. A check that is wrong in the optimistic direction is worse
# than no check at all: it tells a person the platform is up when it is not.
# So the tests below drive lib.sh's checks against a MOCKED world and assert
# they say "no" when the world says no.
#
# Strategy mirrors tests/unit/test_crossplane_trace.sh: shim `aws` and
# `kubectl` onto PATH and describe the fake world with environment variables.
# No AWS, no cluster, no network.
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

LIB="scripts/opsbox/lib.sh"
MOCK_DIR="$(mktemp -d -t opsbox-mock-XXXXXX)"
trap 'rm -rf "$MOCK_DIR"' EXIT

# ---------------------------------------------------------------------------
# Shims. Each returns whatever the current MOCK_* variables describe.
# ---------------------------------------------------------------------------
cat > "$MOCK_DIR/aws" <<'SHIM'
#!/usr/bin/env bash
set -u
svc="${1:-}"; op="${2:-}"
case "$svc $op" in
  "sts get-caller-identity") printf '%s\n' "${MOCK_ACCOUNT:-123456789012}" ;;
  "route53 list-hosted-zones") printf '%s\n' "${MOCK_ZONE:-example.com.}" ;;
  "acm list-certificates") printf '%s\n' "${MOCK_ACM_STATUS:-ISSUED}" ;;
  "cognito-idp list-user-pools") printf '%s\n' "${MOCK_POOL_COUNT:-1}" ;;
  "eks describe-cluster") printf '%s\n' "${MOCK_CLUSTER_STATUS:-ACTIVE}" ;;
  "eks list-nodegroups") printf '%s\n' "${MOCK_NODEGROUP:-ng-1}" ;;
  "eks describe-nodegroup") printf '%s\n' "${MOCK_NODEGROUP_STATUS:-ACTIVE}" ;;
  "eks update-kubeconfig") exit "${MOCK_KUBECONFIG_RC:-0}" ;;
  "s3api list-objects-v2") printf '%s\n' "${MOCK_STATE_OBJECTS:-1}" ;;
  "dynamodb get-item") printf '%s\n' "${MOCK_STATE_LOCK:-None}" ;;
  "eks describe-access-entry"|"eks create-access-entry"|"eks associate-access-policy") exit 0 ;;
  *) exit 0 ;;
esac
SHIM

cat > "$MOCK_DIR/kubectl" <<'SHIM'
#!/usr/bin/env bash
set -u
# The interesting reads are driven by which jsonpath the caller asked for.
all="$*"
case "$all" in
  *"get application bootstrap"*)          printf '%s' "${MOCK_BOOTSTRAP:-ok}" ;;
  *"application crossplane-resources"*)   printf '%s' "${MOCK_CROSSPLANE_RES:-Synced Healthy}" ;;
  *"operationState.phase"*)               printf '%s' "${MOCK_GATE_OPSTATE:-}" ;;
  *"xplatformcluster"*)                   printf '%s' "${MOCK_FACTS:-}" ;;
  *"nodegroups.eks"*)                     printf '%s' "${MOCK_NG_READY:-True}" ;;
  *"xspokeaccess"*)                       printf '%s' "${MOCK_SPOKE_READY:-True}" ;;
  *"get applications --no-headers"*)      printf '%s\n' "${MOCK_APPS:-}" ;;
  *) printf '' ;;
esac
exit 0
SHIM

cat > "$MOCK_DIR/curl" <<'SHIM'
#!/usr/bin/env bash
printf '%s' "${MOCK_HTTP_CODE:-200}"
SHIM

chmod +x "$MOCK_DIR"/aws "$MOCK_DIR"/kubectl "$MOCK_DIR"/curl

# run_check <check-fn> — source lib.sh with the shims on PATH and run one check.
run_check() {
  PATH="$MOCK_DIR:$PATH" bash -c "
    . '$LIB' >/dev/null 2>&1
    $1
  " >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# The design rule, enforced mechanically
# ---------------------------------------------------------------------------
echo "── the scripts ask the world, never GitHub ──"
# If these scripts ever query the GitHub API for build status, two things break
# at once: the box needs a token (it is credential-free by design), and "green"
# starts meaning "the run said so" rather than "the platform works". The
# workflow UI URL is a link printed for the operator, not an API call.
if grep -REn 'api\.github\.com|GH_TOKEN|GITHUB_TOKEN|gh (run|api|workflow)' scripts/opsbox/ >/dev/null 2>&1; then
  _fail "no_github_api_calls" "$(grep -REn 'api\.github\.com|GH_TOKEN|GITHUB_TOKEN|gh (run|api|workflow)' scripts/opsbox/ | head -3)"
else
  _pass "no_github_api_calls"
fi

# ---------------------------------------------------------------------------
# A gate is confirmed by its completed operation (the kp-2al.24 class)
# ---------------------------------------------------------------------------
echo "── gate confirmation ──"
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

MOCK_GATE_OPSTATE="Succeeded $SHA Synced" \
  run_check "gate_synced_at platform-cluster-claim $SHA" \
  && _pass "accepts a completed sync at the right SHA" \
  || _fail "accepts a completed sync at the right SHA"

# The defect this replaced: Argo populates .status.sync.revision from the
# OBSERVED target revision, so an Application that has never synced can report
# the right SHA. A confirmation that passes here would be vacuous.
MOCK_GATE_OPSTATE=" $SHA OutOfSync" \
  run_check "gate_synced_at platform-cluster-claim $SHA" \
  && _fail "rejects the right SHA with no completed operation" \
  || _pass "rejects the right SHA with no completed operation"

MOCK_GATE_OPSTATE="Succeeded bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb Synced" \
  run_check "gate_synced_at platform-cluster-claim $SHA" \
  && _fail "rejects a completed sync at the WRONG SHA" \
  || _pass "rejects a completed sync at the WRONG SHA"

MOCK_GATE_OPSTATE="Failed $SHA Synced" \
  run_check "gate_synced_at platform-cluster-claim $SHA" \
  && _fail "rejects a failed operation" \
  || _pass "rejects a failed operation"

# ---------------------------------------------------------------------------
# Gate 1 needs ALL FOUR published facts
# ---------------------------------------------------------------------------
echo "── gate 1 requires four facts and a Ready node group ──"
MOCK_FACTS="iss|ep|ca|arn" MOCK_NG_READY=True \
  run_check check_gate1 && _pass "four facts + Ready node group" || _fail "four facts + Ready node group"

MOCK_FACTS="iss|ep||arn" MOCK_NG_READY=True \
  run_check check_gate1 && _fail "rejects a missing middle fact" || _pass "rejects a missing middle fact"

MOCK_FACTS="|ep|ca|arn" MOCK_NG_READY=True \
  run_check check_gate1 && _fail "rejects a missing first fact" || _pass "rejects a missing first fact"

MOCK_FACTS="iss|ep|ca|" MOCK_NG_READY=True \
  run_check check_gate1 && _fail "rejects a missing last fact" || _pass "rejects a missing last fact"

MOCK_FACTS="" MOCK_NG_READY=True \
  run_check check_gate1 && _fail "rejects no facts at all" || _pass "rejects no facts at all"

MOCK_FACTS="iss|ep|ca|arn" MOCK_NG_READY=False \
  run_check check_gate1 && _fail "rejects an un-Ready node group" || _pass "rejects an un-Ready node group"

# ---------------------------------------------------------------------------
# Convergence: workload1-cluster is OutOfSync BY DESIGN, nothing else may be
# ---------------------------------------------------------------------------
echo "── convergence ──"
converged_apps() {
  printf 'app%02d Synced Healthy\n' $(seq 1 16)
  printf 'workload1-cluster OutOfSync Healthy\n'
}
GOOD="$(converged_apps)"

MOCK_APPS="$GOOD" run_check check_converged \
  && _pass "17 apps, only workload1-cluster OutOfSync" \
  || _fail "17 apps, only workload1-cluster OutOfSync"

BAD="$(printf '%s\n' "$GOOD" | sed 's/^app03 Synced Healthy/app03 OutOfSync Healthy/')"
MOCK_APPS="$BAD" run_check check_converged \
  && _fail "rejects another OutOfSync Application" \
  || _pass "rejects another OutOfSync Application"

DEGRADED="$(printf '%s\n' "$GOOD" | sed 's/^app07 Synced Healthy/app07 Synced Degraded/')"
MOCK_APPS="$DEGRADED" run_check check_converged \
  && _fail "rejects a Degraded Application" \
  || _pass "rejects a Degraded Application"

SHORT="$(printf '%s\n' "$GOOD" | head -8)"
MOCK_APPS="$SHORT" run_check check_converged \
  && _fail "rejects a short Application list (spoke never fanned out)" \
  || _pass "rejects a short Application list (spoke never fanned out)"

MOCK_APPS="" run_check check_converged \
  && _fail "rejects an empty Application list" \
  || _pass "rejects an empty Application list"

# ---------------------------------------------------------------------------
# base / management / endpoint
# ---------------------------------------------------------------------------
echo "── other stage checks ──"
MOCK_ACM_STATUS=ISSUED MOCK_POOL_COUNT=1 run_check check_base \
  && _pass "base: ISSUED certificate + user pool" || _fail "base: ISSUED certificate + user pool"

MOCK_ACM_STATUS=PENDING_VALIDATION MOCK_POOL_COUNT=1 run_check check_base \
  && _fail "base: rejects a certificate that is not ISSUED" \
  || _pass "base: rejects a certificate that is not ISSUED"

MOCK_ACM_STATUS=ISSUED MOCK_POOL_COUNT=0 run_check check_base \
  && _fail "base: rejects a missing user pool" || _pass "base: rejects a missing user pool"

# A phase is applied only when its apply has FINISHED. On build #9 the
# certificate was ISSUED and the pool existed ~2 min before base's apply had
# written its state; a check on those alone sent the operator to management
# against unfinished base state. The state object must exist and its lock
# must be free.
MOCK_ACM_STATUS=ISSUED MOCK_POOL_COUNT=1 MOCK_STATE_OBJECTS=0 run_check check_base \
  && _fail "base: rejects cert+pool when base's state has not been written" \
  || _pass "base: rejects cert+pool when base's state has not been written"

MOCK_ACM_STATUS=ISSUED MOCK_POOL_COUNT=1 MOCK_STATE_LOCK="bucket/k8-platform/base/terraform.tfstate" run_check check_base \
  && _fail "base: rejects cert+pool while base's apply still holds the lock" \
  || _pass "base: rejects cert+pool while base's apply still holds the lock"

MOCK_CLUSTER_STATUS=ACTIVE MOCK_NODEGROUP_STATUS=ACTIVE MOCK_STATE_LOCK="bucket/k8-platform/management/terraform.tfstate" run_check check_management \
  && _fail "management: rejects a live hub while management's apply still holds the lock" \
  || _pass "management: rejects a live hub while management's apply still holds the lock"

MOCK_CLUSTER_STATUS=ACTIVE MOCK_NODEGROUP_STATUS=ACTIVE run_check check_management \
  && _pass "management: ACTIVE cluster + node group + bootstrap + settled state" \
  || _fail "management: ACTIVE cluster + node group + bootstrap + settled state"

MOCK_CLUSTER_STATUS=CREATING run_check check_management \
  && _fail "management: rejects a cluster that is still CREATING" \
  || _pass "management: rejects a cluster that is still CREATING"

MOCK_CLUSTER_STATUS=ACTIVE MOCK_NODEGROUP_STATUS=CREATING run_check check_management \
  && _fail "management: rejects a node group that is not ACTIVE" \
  || _pass "management: rejects a node group that is not ACTIVE"

MOCK_HTTP_CODE=200 run_check check_endpoint \
  && _pass "endpoint: 200 is green" || _fail "endpoint: 200 is green"

MOCK_HTTP_CODE=000 run_check check_endpoint \
  && _fail "endpoint: rejects 000" || _pass "endpoint: rejects 000"

MOCK_HTTP_CODE=503 run_check check_endpoint \
  && _fail "endpoint: rejects 503" || _pass "endpoint: rejects 503"

# ---------------------------------------------------------------------------
# Static hygiene
# ---------------------------------------------------------------------------
echo "── static ──"
for f in scripts/opsbox/*.sh; do
  bash -n "$f" 2>/dev/null && _pass "syntax: $f" || _fail "syntax: $f"
done

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x scripts/opsbox/*.sh >/dev/null 2>&1; then
    _pass "shellcheck clean"
  else
    _fail "shellcheck clean" "$(shellcheck -x scripts/opsbox/*.sh 2>&1 | head -5)"
  fi
else
  echo "  (shellcheck not installed — skipping)"
fi

# Every Terraform module must be in the validate matrix, or it is never
# validated at all — terraform/opsbox was added and the matrix was a hardcoded
# list of two.
echo "── every terraform module is validated in CI ──"
if command -v yq >/dev/null 2>&1; then
  matrix="$(yq eval '.jobs.*.strategy.matrix.module[]' .github/workflows/terraform-validate.yml 2>/dev/null | sort | tr '\n' ' ')"
  missing=""
  for d in terraform/*/; do
    m="$(basename "$d")"
    case " $matrix " in *" $m "*) ;; *) missing="$missing $m" ;; esac
  done
  if [ -z "$missing" ]; then
    _pass "terraform-validate matrix covers every module"
  else
    _fail "terraform-validate matrix covers every module" "not in the matrix:$missing"
  fi
else
  echo "  (yq not installed — skipping)"
fi

# ---------------------------------------------------------------------------
# The two workflows must agree on the state backend's NAME
# ---------------------------------------------------------------------------
# opsbox.yml bootstraps the backend itself so the ops box can exist before any
# platform phase. That is a deliberate second implementation of the MINIMUM,
# with terraform-test.yml remaining the authority on versioning/encryption. The
# one thing that must not drift is the naming: if the two disagree, the ops box
# writes its state into a bucket the platform build never looks at, and neither
# notices.
echo "── the two workflows agree on the backend name ──"
name_bits() {
  grep -hoE 'k8-platform-tfstate-[$][{]?ACCOUNT_ID[}]?|k8-platform-tfstate-lock' "$1" \
    | sort -u | tr '\n' ' '
}
tt="$(name_bits .github/workflows/terraform-test.yml)"
ob="$(name_bits .github/workflows/opsbox.yml)"
if [ -n "$ob" ] && [ "$tt" = "$ob" ]; then
  _pass "state backend naming matches ($ob)"
else
  _fail "state backend naming matches" "terraform-test: [$tt]  opsbox: [$ob]"
fi

# ---------------------------------------------------------------------------
# The ops box must not pick an Availability Zone blindly
# ---------------------------------------------------------------------------
# The first real apply failed with:
#   "Your requested instance type (t3.small) is not supported in your requested
#    Availability Zone (us-east-1e)"
# The default VPC has a subnet in EVERY AZ, including ones that offer no t3 at
# all, so choosing `sort(data.aws_subnets.default.ids)[0]` is a coin flip that
# lands on a dead AZ. The module must ask which AZs actually offer the type.
echo "── the ops box picks an AZ that offers its instance type ──"
TF=terraform/opsbox/main.tf
if grep -q 'aws_ec2_instance_type_offerings' "$TF"; then
  _pass "module consults instance-type offerings"
else
  _fail "module consults instance-type offerings" \
    "$TF picks a subnet without checking which AZs offer var.instance_type"
fi

if grep -qE 'subnet_id[[:space:]]*=[[:space:]]*sort\(data\.aws_subnets' "$TF"; then
  _fail "module does not pick a subnet blindly" \
    "subnet_id is back to an unfiltered pick from data.aws_subnets.default"
else
  _pass "module does not pick a subnet blindly"
fi

assert_summary
