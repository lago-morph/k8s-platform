# ADR: Upgrade components straight to the target release on a from-scratch platform

- **ID**: ADR-b12417e75f
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-11-28
- **Source retrospective**: ../2026-11-28-296.md
- **PRs covered**: #292 (Argo CD 2.10.4 → 3.6.3), #284 (Kubernetes 1.37)

## Context

Step 3.1 was planned with the owner rule "one major version at a time, each
its own PR" — sensible for a long-lived system, where every live hop must be
survivable. The step 3 test build (account 478728046113) then showed Argo CD
v2.10.4 cannot manage a Kubernetes ≥ 1.35 cluster: every Deployment-backed
Application failed with `ComparisonError … .status.terminatingReplicas: field
not declared in schema` (Kubernetes enables `DeploymentReplicaSetTerminatingReplicas`
by default from 1.35), and a completed ingress-nginx hook Job was reported
"Running" forever. The 3.1 enrichment had already split the Argo CD upgrade
into four sequential PRs (2.14 → 3.0 → 3.4 → 3.6), each needing its own build
to prove.

This platform is intentionally ephemeral: every build starts from an empty AWS
account. There is no live Argo CD to migrate, no persisted controller state,
and no user data in its CRs that an intermediate release would need to
transform.

## Decision

Because every build starts from an empty account, a component upgrade jumps
directly to the target release in one change, adapting configuration to every
intervening breaking change, instead of stepping one major version at a time.

The PR must enumerate each intervening breaking change (from upstream upgrade
notes, every hop) and say how it is handled or why it does not apply; prove the
target locally where possible (kind at the platform's Kubernetes version, with
the repo's real manifests); and prove it on a from-scratch build.

## Alternatives considered

- **One major per PR (the original 3.1 plan).** Four PRs and four builds for
  Argo CD alone, each intermediate release untested on Kubernetes 1.37 anyway
  (2.14 tested ≤ 1.31). Rejected: the intermediate states never exist in
  production here, so testing them buys nothing.
- **Keep Kubernetes at 1.34 so Argo CD 2.10 keeps working.** EKS standard
  support for 1.34 ended within days (2026-12-02), moving the clusters to
  extended-support pricing immediately. Rejected by the owner.
- **Patch around it in 2.10** (drop `ServerSideApply` to avoid the structured
  merge diff). Uncertain to fix the hook-tracking symptom, and a hack to undo
  in 3.1. Rejected.

## Consequences

- Easier: one PR and one build per component; the target is what gets tested.
- Harder: each jump PR carries a long breaking-change audit; a mistake in it
  surfaces only on a build. Mitigated by the kind proof (#292's agent
  reproduced both production failures on 2.10 and cleared them on 3.6 before
  any EKS time) and by Live verify's full verdict.
- In-place upgrades of a running platform are explicitly unsupported (the test
  build's in-place jump left two gates OutOfSync with empty diffs because Argo
  CD 3 tracks objects by annotation, not label); fresh builds are the contract.
  Kubernetes in-place minor upgrades are tracked separately (kp-zab.8).
- The "one major at a time" rule still applies to anything that cannot be
  rebuilt from scratch (e.g. the beads database, kp-uvy.14).

## References

- [`../2026-11-28-296.md`](../2026-11-28-296.md) — the source retrospective (Phase 7).
- `tests/unit/test_argocd_kubernetes_support.sh` — the guard added with the decision.
- PRs: #292 (merged cd0fc95), #284; beads kp-2al.56, kp-uvy.8.
