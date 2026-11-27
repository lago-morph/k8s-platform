#!/usr/bin/env bash
# Literal ${...} / backticks below are workflow and HCL text, not shell.
# shellcheck disable=SC2016
# kp-2al.36 — the AWS region is a repository VARIABLE, never a secret.
#
# GitHub masks, as `***`, every occurrence in a job log of every secret value
# the job references. With the region read from `secrets.AWS_REGION`, the
# string `us-east-1` was masked everywhere — including the Ops box "How to
# reach it" console URL, which printed as
#   https://***.console.aws.amazon.com/...?region=***
# and was unusable (owner's run 45939416156, 2026-11-27). The region is not
# sensitive; reading it from `vars.AWS_REGION` stops the masking.
#
# This lint pins:
#   1. no workflow or workflow script references `secrets.AWS_REGION`;
#   2. every workflow that carries the AWS credentials takes its region from
#      `vars.AWS_REGION` and fails fast (require-aws-region.sh) when the
#      variable is unset, instead of silently defaulting to some region;
#   3. no silent `${AWS_DEFAULT_REGION:-us-east-1}` fallback remains in CI;
#   4. require-aws-region.sh itself: red and named when unset, green when set;
#   5. the ops box console URL is built from the region variable;
#   6. the human docs say "variable", not "secret", for AWS_REGION.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1   # repo root

# shellcheck disable=SC1091
. tests/lib/assert.sh

WF_DIR=".github/workflows"
GUARD=".github/scripts/require-aws-region.sh"

echo "── 1. no secrets.AWS_REGION anywhere in CI ──"
hits="$(grep -rn 'secrets\.AWS_REGION' "$WF_DIR" .github/scripts 2>/dev/null || true)"
assert_eq "no workflow/script references secrets.AWS_REGION" "" "$hits"

echo "── 2. every AWS-credentialed workflow: region from vars, fail-fast guard ──"
for wf in "$WF_DIR"/*.yml; do
  grep -q 'secrets\.AWS_ACCESS_KEY_ID' "$wf" || continue
  if grep -Eq 'AWS_DEFAULT_REGION: \$\{\{ vars\.AWS_REGION \}\}' "$wf"; then
    _pass "$wf: AWS_DEFAULT_REGION from vars.AWS_REGION"
  else
    _fail "$wf: AWS_DEFAULT_REGION from vars.AWS_REGION" "no 'AWS_DEFAULT_REGION: \${{ vars.AWS_REGION }}' line"
  fi
  if grep -q "$GUARD" "$wf"; then
    _pass "$wf: runs $GUARD"
  else
    _fail "$wf: runs $GUARD" "an unset variable must fail loudly, not run region-less"
  fi
  # Any AWS_REGION / TF_VAR_aws_region env line must come from the variable too.
  bad="$(grep -En '^\s*(AWS_REGION|TF_VAR_aws_region): ' "$wf" | grep -v 'vars\.AWS_REGION' || true)"
  assert_eq "$wf: AWS_REGION/TF_VAR_aws_region only from vars.AWS_REGION" "" "$bad"
done

echo "── 3. no silent region default in CI ──"
# `${X:-}` (empty default, then tested) is fine; `${X:-us-east-1}` is a guess.
silent="$(grep -rnE 'AWS_(DEFAULT_)?REGION:-[^}]' "$WF_DIR" .github/scripts 2>/dev/null || true)"
assert_eq "no \${AWS_DEFAULT_REGION:-...} fallback in .github" "" "$silent"

echo "── 4. $GUARD behaviour ──"
if [ -x "$GUARD" ]; then
  _pass "$GUARD exists and is executable"
  out="$(env -u AWS_DEFAULT_REGION -u AWS_REGION bash "$GUARD" 2>&1)"; rc=$?
  assert_eq "unset variable: guard exits non-zero" "1" "$rc"
  assert_contains "unset variable: message names the AWS_REGION repository variable" \
    "AWS_REGION repository variable" "$out"
  assert_contains "unset variable: message says where to set it" \
    "Settings -> Secrets and variables -> Actions -> Variables" "$out"
  out="$(AWS_DEFAULT_REGION="" bash "$GUARD" 2>&1)"; rc=$?
  assert_eq "empty variable: guard exits non-zero" "1" "$rc"
  out="$(AWS_DEFAULT_REGION=us-east-1 bash "$GUARD" 2>&1)"; rc=$?
  assert_eq "set variable: guard exits 0" "0" "$rc"
  assert_contains "set variable: guard prints the region in clear" "us-east-1" "$out"
  out="$(AWS_DEFAULT_REGION='us east 1' bash "$GUARD" 2>&1)"; rc=$?
  assert_eq "malformed region: guard exits non-zero" "1" "$rc"
else
  _fail "$GUARD exists and is executable"
fi

echo "── 5. ops box console URL is built from the variable ──"
OPS="$WF_DIR/opsbox.yml"
file_has() { # <name> <needle> <file>: a quiet file-level assert_contains
  if grep -qF -- "$2" "$3"; then _pass "$1"; else _fail "$1" "$3 lacks: $2"; fi
}
file_has "opsbox: TF_VAR_aws_region from vars.AWS_REGION" \
  'TF_VAR_aws_region: ${{ vars.AWS_REGION }}' "$OPS"
# The "How to reach it" step: from its `- name:` line to the next `- name:`.
reach="$(awk '/- name: How to reach it/{f=1; print; next} f && /^      - name:/{exit} f' "$OPS")"
assert_contains "opsbox: 'How to reach it' prints terraform's console_url" \
  'terraform output -raw console_url' "$reach"
assert_contains "opsbox: 'How to reach it' checks the URL's shape" \
  'console.aws.amazon.com' "$reach"
# Run the step's script against a stub `terraform` that renders console_url
# exactly as outputs.tf does, from TF_VAR_aws_region.
step_sh="$(printf '%s\n' "$reach" | awk '/^        run: \|/{f=1; next} f' | sed 's/^          //')"
STUB="$(mktemp -d -t region-stub-XXXXXX)"; trap 'rm -rf "$STUB"' EXIT
cat > "$STUB/terraform" <<'SHIM'
#!/usr/bin/env bash
r="${TF_VAR_aws_region:-}"
printf 'https://%s.console.aws.amazon.com/systems-manager/session-manager/i-0abc?region=%s' "$r" "$r"
SHIM
chmod +x "$STUB/terraform"
out="$(PATH="$STUB:$PATH" AWS_DEFAULT_REGION=us-east-1 TF_VAR_aws_region=us-east-1 bash -c "$step_sh" 2>&1)"; rc=$?
assert_eq "How to reach it: region set -> step passes" "0" "$rc"
assert_contains "How to reach it: prints a usable console URL" \
  "https://us-east-1.console.aws.amazon.com/systems-manager/session-manager/i-0abc?region=us-east-1" "$out"
out="$(PATH="$STUB:$PATH" AWS_DEFAULT_REGION="" TF_VAR_aws_region="" bash -c "$step_sh" 2>&1)"; rc=$?
assert_eq "How to reach it: no region -> step fails rather than print a dead URL" "1" "$rc"
url_expr="$(grep -A3 'output "console_url"' terraform/opsbox/outputs.tf | grep 'value')"
assert_contains "console_url hostname is the region variable" \
  'https://${var.aws_region}.console.aws.amazon.com/' "$url_expr"
assert_contains "console_url query string is the region variable" \
  '?region=${var.aws_region}' "$url_expr"

echo "── 6. docs say 'variable', not 'secret' ──"
# Any line, in the human docs, that names AWS_REGION alongside the word
# "secret" — and not "variable" — is telling someone to set it as a secret. admin-access.md is owned
# elsewhere; ai/archive and ai/brainstorming are historical records.
doc_hits="$(grep -rniE 'AWS_REGION.*secret|secret.*AWS_REGION' \
  docs/site README.md ai/environment.md scripts tests/integration/README.md 2>/dev/null \
  | grep -v 'docs/site/how-to/admin-access.md' \
  | grep -viE 'variable|vars\.AWS_REGION' || true)"
assert_eq "no doc tells a human to set an AWS_REGION secret" "" "$doc_hits"
PAGE="docs/site/how-to/build-the-platform-from-nothing.md"
var_section="$(awk '/^### /{f = (tolower($0) ~ /variable/)} f' "$PAGE")"
assert_contains "$PAGE: AWS_REGION is documented under a 'variable' heading" \
  '| `AWS_REGION` |' "$var_section"
file_has "$PAGE: says where repository variables are set" \
  'Settings → Secrets and variables → Actions → Variables' "$PAGE"
secret_section="$(awk '/^### /{f = (tolower($0) ~ /secret/ && tolower($0) !~ /variable/)} f' "$PAGE")"
if printf '%s' "$secret_section" | grep -qF '| `AWS_REGION` |'; then
  _fail "$PAGE: AWS_REGION is not in a secrets table"
else
  _pass "$PAGE: AWS_REGION is not in a secrets table"
fi

assert_summary
