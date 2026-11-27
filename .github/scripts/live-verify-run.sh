#!/usr/bin/env bash
# Live-suite EVIDENCE PRODUCER body (FINAL-PLAN §4; burndown item 4).
#
# Invoked by .github/workflows/live-verify.yml. Kept as a script (not inline
# YAML) so the wired/gating/scoped lint (tests/unit/test_live_suite_wired.sh)
# can assert it, and so the logic is reviewable/testable on its own.
#
# Runs tests/live/run.sh under the SCOPED verifier/reaper role (NOT admin creds)
# and, on a clean pass ONLY, writes the unforgeable live-evidence record the
# push-time live-evidence gate consumes.
#
# FULL VERDICT (kp-2al.37, owner ruling 2026-11-27): the run is MUTATING and
# STRICT — every check runs, and a skip without a SKIP_REGISTER entry is a FAIL.
# Checks whose header declares `# live-identity: cluster` (relay + Kubernetes
# access, Cognito fixture users) run under the job's own credentials via the
# `live-cluster` AWS profile; the owner chose that identity over widening the
# scoped role (step 6 bead tracks tightening it). Everything else — the AWS-API
# checks, the reaper and the account mutex — stays on the scoped role.
#
#   GATING : success is run.sh's exit code (set -e, no `|| true`, no `&`).
#   SCOPED : run.sh runs under `aws sts assume-role` + the required live-verify
#            session tag (trust demands aws:RequestTag/live-verify).
#
# Env in : LIVE_PROFILE (full|verify-only; default full), GITHUB_RUN_ID,
#          GITHUB_RUN_ATTEMPT, GITHUB_SHA, EVIDENCE_DIR (where to write evidence).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/../.." && pwd)"   # repo root
PROFILE="${LIVE_PROFILE:-full}"
EVIDENCE_DIR="${EVIDENCE_DIR:-${RUNNER_TEMP:-/tmp}/live-evidence}"
CLUSTER="k8-platform-mgmt"   # mgmt cluster name (stable var default, not account-derived)

# kp-2al.36: the region is the AWS_REGION repository variable; never guess one.
bash "$HERE/.github/scripts/require-aws-region.sh"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

# Cluster identity: the job's credentials as a named profile, written to a
# private temp file BEFORE the env is switched to the scoped role. Never echoed.
LIVE_AWS_DIR="$(mktemp -d)"; chmod 700 "$LIVE_AWS_DIR"
export AWS_SHARED_CREDENTIALS_FILE="$LIVE_AWS_DIR/credentials"
export AWS_CONFIG_FILE="$LIVE_AWS_DIR/config"
( umask 077
  printf '[live-cluster]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
    "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" > "$AWS_SHARED_CREDENTIALS_FILE"
  printf '[profile live-cluster]\nregion = %s\n' "${AWS_DEFAULT_REGION}" > "$AWS_CONFIG_FILE" )
trap 'rm -rf "$LIVE_AWS_DIR"' EXIT
export LIVE_CLUSTER_AWS_PROFILE="live-cluster"
echo "cluster-access identity: $(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
  AWS_PROFILE=live-cluster aws sts get-caller-identity --query Arn --output text)"

ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${CLUSTER}-live-verifier-reaper"
RUN_TAG="gha-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}"

# SCOPED: assume the verifier/reaper role WITH the required live-verify session
# tag (sts:TagSession granted alongside sts:AssumeRole). run.sh then runs ONLY
# under these temp creds — never the admin job creds.
CREDS="$(aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "live-verify-${GITHUB_RUN_ID:-local}" \
  --tags "Key=live-verify,Value=${RUN_TAG}" \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
  --output text)"
AWS_ACCESS_KEY_ID="$(printf '%s' "$CREDS" | cut -f1)"
AWS_SECRET_ACCESS_KEY="$(printf '%s' "$CREDS" | cut -f2)"
AWS_SESSION_TOKEN="$(printf '%s' "$CREDS" | cut -f3)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
echo "live suite identity: $(aws sts get-caller-identity --query Arn --output text)"

# Per-bring-up coverage declaration (scope-and-grow, burndown item 4): the set of
# kinds the producer COMMITS to verifying with a passing behavioral check. It
# GROWS only as fast as the live account actually provisions each kind -- a
# declared-but-unprovisioned kind correctly goes RED; we do NOT green-wash by
# narrowing. Until P2's per-cluster git-declaration automates it, it is explicit.
#
# auto-014: broadened from {rds} to the 10 AWS-describe kinds whose read-only
# after-tier check is (a) provisioned + healthy in this account and (b) runnable
# under the SCOPED verifier/reaper role on a CI runner (pure aws describe/list --
# no kubectl/relay). Kinds deliberately LEFT OUT and why:
#   - ec2 SecurityGroupRule, external-secrets ExternalSecret: need kubectl + the
#     SSM relay, which the CI runner does not have -> they SKIP in CI (correct).
#   - iam OpenIDConnectProvider, iam RolePolicy: joined 2026-07-05 (build #5)
#     — both PASSED under the scoped role on run 28759141867 (the spoke IRSA
#     OIDC provider + the eso inline policy are real now).
#   - secretsmanager Secret: joined 2026-07-05 — the ADR-0012 material chain
#     writes AWSCURRENT into the MR-owned container (PASSED on 28759141867);
#     the "value-less chainsaw leftover" era is over.
# These join expect-full the moment they are genuinely provisioned/CI-runnable.
#
# REQUIRES: the scoped role's read-verb allowlist must already grant
# acm:ListTagsForCertificate, iam:ListRoles, iam:ListRoleTags (added alongside
# this change in terraform/management/policies/verifier-reaper-policy.json.tftpl).
# That policy takes effect on `terraform apply`; until applied, the acm/iam/
# route53 checks SKIP under the scoped role and this producer goes RED. Sequence:
# merge -> terraform apply (mgmt) -> dispatch live-verify -> GREEN.
#
# kp-2al.4 adds eks.aws.m.upbound.io/Addon (the spoke aws-ebs-csi-driver) to
# the list below. Same sequence applies twice over: the scoped role needs
# eks:DescribeAddon/ListAddons (terraform apply), and the addon itself only
# exists after a clean build re-renders XSpokeAccess. Until both, the Addon
# check SKIPs and this producer is correctly RED — the addon is declared in
# git, so an absent one is a real expect-full violation, not a green.
export LIVE_EXPECT_FULL="rds.aws.m.upbound.io/Instance
secretsmanager.aws.m.upbound.io/Secret
iam.aws.m.upbound.io/OpenIDConnectProvider
iam.aws.m.upbound.io/RolePolicy
acm.aws.m.upbound.io/Certificate
acm.aws.m.upbound.io/CertificateValidation
eks.aws.m.upbound.io/Cluster
eks.aws.m.upbound.io/NodeGroup
eks.aws.m.upbound.io/AccessEntry
eks.aws.m.upbound.io/AccessPolicyAssociation
eks.aws.m.upbound.io/Addon
iam.aws.m.upbound.io/Role
iam.aws.m.upbound.io/RolePolicyAttachment
route53.aws.m.upbound.io/Record"
# LIVE_CLUSTER is the cluster UNDER TEST — the platform-services spoke, where the
# ExternalSecrets, PVCs and workloads live (same as the oracle recipe). The
# evidence record keeps CLUSTER (the hub) as its key; the gate matches on that.
export LIVE_CLUSTER="k8-platform-services"
export LIVE_HUB_CLUSTER="$CLUSTER"
export LIVE_PROFILE="$PROFILE"
export LIVE_STRICT_SKIPS=1
export LIVE_SHARED_TUNNELS="$CLUSTER k8-platform-services"
export LIVE_PARALLEL="${LIVE_PARALLEL:-8}"
export AWS_REGION="${AWS_DEFAULT_REGION}"
MODE="mutating"
[ "$PROFILE" = "verify-only" ] && MODE="readonly"   # verify-only has nothing to mutate

# GATING: this IS the build's verdict — run.sh's exit code is not swallowed.
bash "$HERE/tests/live/run.sh" "$MODE"

# Evidence is machine-emitted on the clean-pass ONLY (reached only if run.sh
# exited 0). Schema matches .github/scripts/live-evidence-gate.sh.
mkdir -p "$EVIDENCE_DIR"
ACCOUNT="$ACCOUNT" CLUSTER="$CLUSTER" PROFILE="$PROFILE" \
  python3 - > "${EVIDENCE_DIR}/live-evidence.json" <<'PY'
import json, os, datetime
print(json.dumps({
    "run_id":     os.environ.get("GITHUB_RUN_ID", "local"),
    "sha":        os.environ.get("GITHUB_SHA", ""),
    "account":    os.environ["ACCOUNT"],
    "cluster":    os.environ["CLUSTER"],
    "profile":    os.environ["PROFILE"],
    "conclusion": "success",
    "created_at": datetime.datetime.now(datetime.timezone.utc)
                    .strftime("%Y-%m-%dT%H:%M:%SZ"),
}))
PY
echo "wrote live-evidence:"; cat "${EVIDENCE_DIR}/live-evidence.json"
