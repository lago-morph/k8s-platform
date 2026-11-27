# Spoke EKS control-plane log groups, with bounded retention (kp-2al.45).
#
# The platform-cluster Composition turns on api/audit/authenticator logging
# for every spoke. EKS then writes to /aws/eks/<cluster>/cluster, and if that
# group does not exist EKS creates it with NEVER-EXPIRE retention. Nothing the
# Composition can express sets retention on a group EKS creates, and the
# Crossplane provider family installed here has no CloudWatch Logs provider.
# So this module creates the groups first: EKS writes into an existing group
# and keeps its retention. `terraform destroy` removes them; the teardown
# deletes the XRs (stage 4) before destroying this module (stage 5).
#
# The spoke names come from the XR files ArgoCD syncs (clusters/**), so there
# is no second list to keep in step. An XR is one YAML document; a file
# containing one is matched by its `kind:` line and yamldecode()d whole
# (tests/unit/test_control_plane_logging.sh guards both).
#
# Ordering: this module is applied before any spoke XR is synced, so on a
# build from nothing the groups always exist first. A spoke created BEFORE
# this file existed already has an EKS-made group; importing it is the fix
# (`terraform import 'aws_cloudwatch_log_group.spoke_control_plane["<name>"]'
# /aws/eks/<name>/cluster`), not deleting it.

locals {
  clusters_dir = "${path.module}/../../clusters"

  spoke_xrs = {
    for f in fileset(local.clusters_dir, "**/*.yaml") :
    yamldecode(file("${local.clusters_dir}/${f}")).spec.name => yamldecode(file("${local.clusters_dir}/${f}")).spec.region
    if can(regex("(?m)^kind: XPlatformCluster\\s*$", file("${local.clusters_dir}/${f}")))
  }
}

resource "aws_cloudwatch_log_group" "spoke_control_plane" {
  for_each = local.spoke_xrs

  name              = "/aws/eks/${each.key}/cluster"
  retention_in_days = var.control_plane_log_retention_days

  tags = {
    Cluster = each.key
    Purpose = "eks-control-plane-logs"
  }

  lifecycle {
    precondition {
      condition     = each.value == var.aws_region
      error_message = "XPlatformCluster ${each.key} is in ${each.value}; this module creates its log group in ${var.aws_region} only."
    }
  }
}
