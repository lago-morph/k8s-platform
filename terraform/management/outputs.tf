output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for the EKS cluster"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider — used by downstream IRSA role modules"
  value       = module.eks.oidc_provider_arn
}

output "kube_relay_instance_id" {
  description = "EC2 instance id of the SSM kube-API relay (target for `aws ssm start-session` from the sandbox; see scripts/sandbox-kubeconfig.sh)."
  value       = aws_instance.kube_relay.id
}

output "irsa_crossplane_role_arn" {
  description = "IAM role ARN for Crossplane AWS provider"
  value       = module.irsa_crossplane.iam_role_arn
}

output "irsa_eso_role_arn" {
  description = "IAM role ARN for External Secrets Operator"
  value       = module.irsa_eso.iam_role_arn
}

output "argocd_url" {
  description = "ArgoCD UI URL (valid once the ACM cert is bound to the ingress NLB)"
  value       = "https://argocd.management.${var.domain}"
}

# ArgoCD driving credentials (AGENTS §10.1). The admin password's
# AUTHORITATIVE home is AWS Secrets Manager (kp-2al.44), the secret named by
# argocd_admin_secret_name. Read it there:
#   scripts/k8p-argocd-password.sh show --reveal
#   aws secretsmanager get-secret-value \
#     --secret-id k8-platform/management/argocd-admin --query SecretString --output text
# and change it only with `scripts/k8p-argocd-password.sh set`.
output "argocd_server_url" {
  description = "ArgoCD server URL for `argocd login` (AGENTS §10.1)."
  value       = "https://argocd.management.${var.domain}"
}

output "argocd_admin_secret_name" {
  description = "AWS Secrets Manager secret holding the ArgoCD admin password (user admin). Authoritative; change it with scripts/k8p-argocd-password.sh."
  value       = aws_secretsmanager_secret.argocd_admin.name
}

# Kept so existing readers keep working, but it is a MIRROR of ASM's
# AWSCURRENT as of the last plan/refresh: not the seed, and not live. After a
# scripted change it is stale until the next apply or refresh; prefer ASM.
output "argocd_admin_password" {
  description = "Mirror of the ASM ArgoCD admin password as of the last refresh. ASM (argocd_admin_secret_name) is authoritative."
  value       = data.aws_secretsmanager_secret_version.argocd_admin.secret_string
  sensitive   = true
}
