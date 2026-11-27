# ArgoCD admin credential. AWS Secrets Manager is AUTHORITATIVE (kp-2al.44):
# Terraform only SEEDS `k8-platform/management/argocd-admin` on a fresh
# account; after that the password is changed with
# scripts/k8p-argocd-password.sh, which writes a new AWSCURRENT version and
# applies it to Argo CD. Read the current value from ASM (that script's
# `show --reveal`, or `aws secretsmanager get-secret-value`), not from
# Terraform state. A session drives ArgoCD (sync the platform-cluster XR,
# query Application sync/health, refresh) with this credential and the
# argocd CLI instead of standing cluster creds — AGENTS.md history §10.1/§6.22.

resource "random_password" "argocd_admin" {
  length = 24
  # Alphanumeric only — the seed is easy to paste and needs no quoting
  # anywhere. (Values set later with the script may contain anything.)
  special = false
}

# recovery_window_in_days = 0 for the same reason as k8-platform/base/cognito
# (terraform/base/cognito.tf): the account is ephemeral, and a
# teardown/rebuild re-creates this deterministic name immediately; a recovery
# window would make that create fail with "scheduled for deletion".
resource "aws_secretsmanager_secret" "argocd_admin" {
  name                    = "k8-platform/management/argocd-admin"
  description             = "Argo CD admin password (user admin). Authoritative; change with scripts/k8p-argocd-password.sh - kp-2al.44"
  recovery_window_in_days = 0

  tags = {
    Name = "${local.name_prefix}-argocd-admin"
  }
}

# The seed version. ignore_changes is the whole point: once the script has
# written a new AWSCURRENT version, a re-apply must never put the seed back.
# (The seed version becomes AWSPREVIOUS, then label-less; ASM purges
# label-less versions only beyond 100 versions, so this resource keeps
# refreshing cleanly for any realistic number of changes.)
resource "aws_secretsmanager_secret_version" "argocd_admin" {
  secret_id     = aws_secretsmanager_secret.argocd_admin.id
  secret_string = random_password.argocd_admin.result

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# The CURRENT ASM value, read for the argocd_admin_password output only — a
# convenience mirror as of the last plan/refresh. ASM is the truth.
data "aws_secretsmanager_secret_version" "argocd_admin" {
  secret_id  = aws_secretsmanager_secret.argocd_admin.id
  depends_on = [aws_secretsmanager_secret_version.argocd_admin]
}

# Patch the bcrypt hash of the CURRENT ASM value into argocd-secret in a
# local-exec. The value is read from ASM at run time, never interpolated from
# random_password: after a scripted change, a re-trigger
# (`terraform apply -replace=terraform_data.argocd_admin_password`) re-applies
# what ASM holds, not the seed. It reaches htpasswd on stdin (-i), so it is
# never on a process command line.
#
# The bcrypt is computed IN the provisioner (htpasswd), NOT via Terraform's
# bcrypt() function — bcrypt() re-salts on every plan and would show a
# perpetual diff. triggers_replace on the seed version's id means this only
# re-runs when the secret is (re)created (e.g. a fresh account). The $2y->$2a
# rewrite is required: Go's bcrypt (ArgoCD) accepts $2a/$2b but not
# htpasswd's $2y prefix. scripts/k8p-argocd-password.sh applies a change with
# exactly this mechanism.
resource "terraform_data" "argocd_admin_password" {
  triggers_replace = [
    aws_secretsmanager_secret_version.argocd_admin.version_id,
    # 2026-07-05: per-resource kubeconfig path (concurrent update-kubeconfig truncate race, build-#4 runs 28747505753/28749110239).
    "per-resource-kubeconfig-2026-07-05",
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --kubeconfig /tmp/k8-platform-kubeconfig-argocd_admin_password
      export KUBECONFIG=/tmp/k8-platform-kubeconfig-argocd_admin_password
      kubectl wait --for=condition=Available --timeout=300s -n argocd deploy/argocd-server
      if ! command -v htpasswd >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y -qq apache2-utils
      fi
      PW=$(aws secretsmanager get-secret-value \
        --region ${var.aws_region} \
        --secret-id '${aws_secretsmanager_secret.argocd_admin.arn}' \
        --version-stage AWSCURRENT \
        --query SecretString --output text)
      if [ -z "$PW" ]; then
        echo "FAIL: ${aws_secretsmanager_secret.argocd_admin.name} has no AWSCURRENT value" >&2
        exit 1
      fi
      HASH=$(printf '%s\n' "$PW" | htpasswd -niBC 10 "" | tr -d ':\n' | sed 's/$2y/$2a/')
      unset PW
      MTIME=$(date -u +%FT%TZ)
      kubectl -n argocd patch secret argocd-secret --type merge \
        -p "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$MTIME\"}}"
      # Roll the server so it picks up the new admin password immediately.
      kubectl -n argocd rollout restart deploy/argocd-server
      kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
    EOT
  }

  depends_on = [helm_release.argocd, aws_secretsmanager_secret_version.argocd_admin]
}
