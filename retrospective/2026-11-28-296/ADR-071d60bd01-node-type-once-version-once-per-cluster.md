# ADR: Node instance type set once for all clusters; Kubernetes version set once per cluster

- **ID**: ADR-071d60bd01
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-11-28
- **Source retrospective**: ../2026-11-28-296.md
- **PRs covered**: #277, #284, #288

## Context

Moving the clusters to `m5.large` touched five places (hub Terraform variable,
the spoke XR, the XRD default, the Composition base literal, workload1) and
the Kubernetes version had silently diverged: the hub on 1.35 since May while
the spoke XR, XRD default and Composition stayed on 1.32 (EKS extended
support), despite the XRD's own comment saying to keep them in sync. The owner
asked for node types configurable in one place and each cluster's version in
one place.

## Decision

The node instance type for every cluster is the `terraform/management`
variable `node_instance_type`, published to Crossplane through the
`cluster-network` EnvironmentConfig, and each cluster's Kubernetes version is
set only in its own definition, with no defaults elsewhere.

The spoke NodeGroup reads `nodeInstanceTypes` with a `Required` patch policy
(a missing value composes no new NodeGroup rather than letting EKS pick a
default; an existing NodeGroup is kept — verified by render with observed
resources). The XRD has no `instanceTypes` field; `spec.version` is required
with no default; the Composition has no version literal. EKS add-on versions
follow the same pattern (`eks_addon_versions` map, #288).

## Alternatives considered

- **A repo-root config file read by Terraform and Kustomize.** Argo CD syncs
  raw manifests; a second templating layer was needed for the spoke. Rejected
  for the existing EnvironmentConfig channel, which already carries
  account-derived facts.
- **Keep per-XR `instanceTypes` as an optional override.** Re-opens a second
  place to set it. Rejected.
- **One Kubernetes version for all clusters in Terraform.** Clusters legitimately
  upgrade at different times; the owner asked for one place *per cluster*.

## Consequences

- A node-type change is a `management` apply, not a Git sync; Crossplane then
  replaces the spoke NodeGroup.
- `test_cluster_config_single_source.sh` fails on any second place;
  `test_chainsaw_kind_config.sh` holds kind's node image to the hub's minor.
- Changing the Composition while an EnvironmentConfig key is absent leaves
  existing NodeGroups untouched (p&t ignores `Required` when the target exists)
  — safe for merges ahead of the Terraform apply.

## References

- [`../2026-11-28-296.md`](../2026-11-28-296.md) — Phase 1.
- PRs #277 (ceccbd8), #284, #288; beads kp-2al.41, kp-2al.53.
