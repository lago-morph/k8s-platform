#!/usr/bin/env bash
# kp-2al.44 — the Argo CD admin password lives in AWS Secrets Manager, and
# ASM is authoritative.
#
# The bug class this guards: Terraform re-imposing ITS idea of the password.
# Once an operator changes the password with scripts/k8p-argocd-password.sh,
# the ASM value is the truth. If the in-cluster provisioner hashed
# random_password.result directly, or the ASM secret version had no
# ignore_changes, the next apply (or a re-trigger) would silently roll Argo CD
# back to the seed and the documented password would stop working.
#
# Static contract, terraform/management only:
#   1. ASM secret `k8-platform/management/argocd-admin` exists, with a
#      recovery window of 0 (a teardown/rebuild of the same account must be
#      able to re-create the same name immediately).
#   2. Its secret VERSION is seeded from random_password and carries
#      lifecycle { ignore_changes = [secret_string] }.
#   3. The terraform_data provisioner reads the password FROM ASM (aws
#      secretsmanager get-secret-value) and never interpolates
#      random_password.argocd_admin.result.
#   4. The password goes to htpasswd on stdin (-i), never on its argv.
#   5. The argocd_admin_password output is not the raw random_password.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/lib/test-helpers.sh"

TF="$HERE/../../terraform/management/argocd-credentials.tf"
OUT="$HERE/../../terraform/management/outputs.tf"

echo "test_argocd_admin_password_source: $TF"
[ -f "$TF" ] || { echo "  FAIL: missing $TF"; exit 1; }

# block <file> <resource-type> <name> — print one resource/data/output block.
block() {
  awk -v hdr="$2" '
    index($0, hdr) == 1 { on=1; depth=0 }
    on {
      print
      n=split($0, ch, "")
      for (i=1;i<=n;i++) { if (ch[i]=="{") depth++; else if (ch[i]=="}") depth-- }
      if (depth==0 && /}/) exit
    }' "$1"
}

secret="$(block "$TF" 'resource "aws_secretsmanager_secret" "argocd_admin"')"
version="$(block "$TF" 'resource "aws_secretsmanager_secret_version" "argocd_admin"')"
apply="$(block "$TF" 'resource "terraform_data" "argocd_admin_password"')"
output="$(block "$OUT" 'output "argocd_admin_password"')"

if printf '%s' "$secret" | grep -q 'name *= *"k8-platform/management/argocd-admin"'; then
  pass "ASM secret is named k8-platform/management/argocd-admin"
else
  fail "ASM secret is named k8-platform/management/argocd-admin" "no aws_secretsmanager_secret.argocd_admin with that name"
fi

if printf '%s' "$secret" | grep -q 'recovery_window_in_days *= *0'; then
  pass "ASM secret has recovery_window_in_days = 0 (rebuild re-creates the name)"
else
  fail "ASM secret has recovery_window_in_days = 0 (rebuild re-creates the name)"
fi

if printf '%s' "$version" | grep -q 'secret_string *= *random_password\.argocd_admin\.result'; then
  pass "ASM secret version is seeded from random_password"
else
  fail "ASM secret version is seeded from random_password"
fi

if printf '%s' "$version" | tr -d ' \n' | grep -q 'lifecycle{ignore_changes=\[secret_string\]'; then
  pass "ASM secret version has lifecycle ignore_changes = [secret_string]"
else
  fail "ASM secret version has lifecycle ignore_changes = [secret_string]" "a re-apply would overwrite a changed password"
fi

if [ -n "$apply" ] && printf '%s' "$apply" | grep -q 'secretsmanager get-secret-value'; then
  pass "provisioner reads the password from ASM"
else
  fail "provisioner reads the password from ASM" "no 'aws secretsmanager get-secret-value' in terraform_data.argocd_admin_password"
fi

# Only the command body matters for (3); triggers may not reference it either,
# because a trigger on the seed is meaningless once ASM has moved on.
if [ -n "$apply" ] && ! printf '%s' "$apply" | grep -q 'random_password\.argocd_admin'; then
  pass "provisioner never uses random_password directly"
else
  fail "provisioner never uses random_password directly" "terraform_data.argocd_admin_password references random_password.argocd_admin"
fi

if [ -n "$apply" ] && printf '%s' "$apply" | grep -Eq 'htpasswd -[A-Za-z]*i[A-Za-z]*'; then
  pass "password reaches htpasswd on stdin (-i), not argv"
else
  fail "password reaches htpasswd on stdin (-i), not argv"
fi

if [ -n "$output" ] && ! printf '%s' "$output" | grep -q 'random_password'; then
  pass "argocd_admin_password output does not expose the seed"
else
  fail "argocd_admin_password output does not expose the seed" "after a change the seed is stale; the output must follow ASM"
fi

summary
