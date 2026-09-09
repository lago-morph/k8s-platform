# `policies/` — dormant Kyverno audit policies

**Status: dormant. Nothing in this directory is applied to any cluster.**

The hub Kyverno install was removed from `terraform/management` on
2026-09-09 (bead `kp-2al.17`). The eleven `ClusterPolicy` manifests under
[`audit/`](audit/) are **kept in git, unchanged**, so reinstatement is a
re-install rather than a re-author. Reinstatement is tracked as bead
**`kp-caz.1` (v2.0)**.

## What the 11 audit policies checked

Every one is `validationFailureAction: Audit` — they record `PolicyReport`
entries and events and block nothing. All eleven target **hub** (management
cluster) objects only.

| File | Policy | Invariant it recorded |
|---|---|---|
| `audit/01-argocd-server-irsa.yaml` | `argocd-server-irsa-required` | The `argocd-server` SA in `argocd` carries an `eks.amazonaws.com/role-arn` annotation (a missing one silently drops ArgoCD back to the node instance profile). |
| `audit/02-ingress-must-have-class.yaml` | `ingress-must-have-class` | Every Ingress declares `spec.ingressClassName`; a class-less Ingress matches no controller and is silently unmanaged. |
| `audit/03-ingress-managed-by-external-dns.yaml` | `ingress-needs-externaldns-annotation` | An Ingress hosted under our domain carries the `external-dns.alpha.kubernetes.io/hostname` annotation, without which no Route53 record is created (phase-1 bug #7). |
| `audit/04-irsa-rolearn-format.yaml` | `irsa-rolearn-format` | When an SA has the IRSA annotation, its value matches `arn:aws:iam::<12 digits>:role/<name>` — catches empty strings, templating leftovers and account-id typos. |
| `audit/05-no-default-sa-with-workload.yaml` | `no-default-sa-with-workload` | Deployments/StatefulSets do not run on the namespace `default` ServiceAccount (which can never receive IRSA). |
| `audit/06-image-tag-not-latest.yaml` | `image-tag-not-latest` | No `:latest` and no untagged images; unpinned tags produce drift invisible to git. |
| `audit/07-helm-release-labels-required.yaml` | `helm-managed-by-label-required` | Every Deployment in the managed namespaces carries `app.kubernetes.io/managed-by`, so hand-applied resources are distinguishable from Helm/Argo-managed ones. |
| `audit/08-external-dns-annotation-on-services.yaml` | `external-dns-service-hostname-pattern` | An LB Service annotated for ExternalDNS uses a hostname under this cluster's domain — catches cross-environment copy-paste before it becomes a DNS record. |
| `audit/10-spoke-no-cluster-admin-binding.yaml` | `spoke-no-cluster-admin-binding` | Runtime backstop for the spoke blast-radius control: any ClusterRoleBinding to the built-in `cluster-admin` role is flagged unless its subject is an allowlisted platform-owned name (auto-008 S1/S2). |
| `audit/11-appproject-no-wildcard-sourcerepos.yaml` | `appproject-no-wildcard-sourcerepos` | Runtime backstop for the no-wildcard `sourceRepos` invariant on the privileged `hub-addons` / `platform-spoke` AppProjects (the static unit tests guard the in-git manifests; this caught a live hand-edit). |
| `audit/12-xdatabase-rds-constraints.yaml` | `xdatabase-rds-constraints` | Runtime backstop for the XDatabase RDS account constraints: micro/small instance classes, not publicly accessible, ≤100GB, engine `postgres`. |

There is no `09-`; that policy was relocated to an ArgoCD-synced path in
PR #52 and is not part of this bundle.

## Why Kyverno was removed (owner ruling, 2026-09-09)

1. **Node memory.** The dev account's `t3.medium` nodes do not have the
   memory to carry Kyverno alongside the rest of the management stack.
   The admission controller was repeatedly OOM-killed (OI-2026-06-11-2).
2. **The fail-closed admission webhook wedged hub applies.** Kyverno's
   webhook is registered `validate.kyverno.svc-fail`, so during every
   admission-controller down-window *every* hub apply — Terraform,
   ArgoCD syncs, and Crossplane composite reconciles alike — failed.
3. **Nothing enforced is lost.** All eleven `ClusterPolicy` manifests are
   `Audit`-only and hub-only. Removing the engine removes reporting, not
   enforcement: no admission decision changes, and every invariant above
   has a static author-time guard in `tests/unit/` as its floor.

## What was removed with it

- `helm_release.kyverno` and `terraform_data.kyverno_audit_policies` in
  `terraform/management/helm.tf`, plus `var.kyverno_version`.
- The `kyverno` render block in `tests/unit/test_helm_render.sh` and the
  live integration check `tests/integration/07_kyverno_audit_policy.sh`.
- The `kyverno` entries in `scripts/k8s-status.sh` and
  `scripts/diag-component.sh` (the hub has no `kyverno` namespace).

## What was deliberately kept

- **These policy manifests, byte-for-byte.**
- `tests/unit/test_kyverno_policy_lint.sh` and
  `tests/unit/test_kyverno_crd_kinds_qualified.sh` — static lints over the
  files in `audit/`. They need no cluster and no install, and they keep the
  dormant bundle apply-ready for `kp-caz.1`.
- `kubeconform-schemas/kyverno.io/*.json`, so `audit/*.yaml` stays covered
  by `tests/unit/test_kubeconform_manifests.sh`.
- `scripts/kyverno-policies.sh` and `scripts/kyverno-violations.sh`
  (read-only inspection helpers; dormant until reinstatement).

## Reinstating (bead `kp-caz.1`, v2.0)

Restore the two Terraform resources, re-add the render assertions and the
integration check, and re-add `kyverno` to the bootstrap-namespace
allowlist in `tests/unit/test_crossplane_resources_namespace_bootstrap_safe.sh`.
The prerequisite is a node size that can host the admission controller
without OOM; consider `admissionController.replicas`/resource sizing and a
`failurePolicy: Ignore` webhook before re-enabling on a shared hub.
