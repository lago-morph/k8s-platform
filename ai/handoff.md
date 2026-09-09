# Session Handoff — k8s-platform

Verified state only (run IDs, SHAs, PR numbers, account shape). Open work
and next actions live in beads: `bd ready`. The plan and the definition
of "feature complete" live in `ai/roadmap.md`. Keep this file short:
replace stale facts, never append narrative. The pre-2026-09-08 handoff
is archived verbatim at `docs/archive/handoff-2026-09-08.md`.

## Verified 2026-09-09

| Fact | Value | Evidence |
|---|---|---|
| `main` | `96279fd1d5a6fb5d852671e0211aa8c3e7fc9404` (PR #265 merged) | `git log` |
| Clean builds proven | six (#1–#6); rows 1–9 evidenced 3×–5× | `SUBSTRATE-READINESS.md` |
| Rows 10/11 | DONE on clean build #6 (federation + federated kubectl, RUN_ID `build6-2220`) | `SUBSTRATE-READINESS.md` |
| AWS account | rotated Pluralsight sandbox, built out by build #6 | creds probe 34396268449, `scripts/whereami.sh` |
| GHA secrets | valid for that account | creds probe 34396268449 (zone 4/4 PASS; state-backend 2 FAIL = expected pre-bootstrap) |
| CI dispatch from the sandbox | native GitHub MCP `actions_run_trigger` + `get_job_logs` work | runs 34396955442 / 34397369089 / 34412419016 |
| Jentic bridge | still works; hosted execution ends 2026-09-20; only needed for `.github/workflows/**` writes | `mcp__Jentic__list_credentials` deprecation notice |
| Sandbox git push | branch create + force-with-lease OK; non-branch refs and branch deletes HTTP 403 | probes 2026-09-08 (`ai/environment.md` §2) |
| Leftover | branch `probe-delete-me-ref-test` on origin awaits owner deletion | — |

## Environment state

The account rotates between sessions. Assume every phase `not applied`
until `scripts/whereami.sh` and the live API prove otherwise. When a
build is in progress, record the chain here as facts (probe → base →
management → gate SHAs → oracle RUN_ID → live-verify run ID) and move
them into `SUBSTRATE-READINESS.md` when the build completes.

Build #6 state as verified 2026-09-09 (account `801822495028`, us-east-1, <!-- noqa: account-id - run provenance, account rotates -->
Route53 zone `Z08868662UCA0EHI3H5KH` / `801822495028.realhandsonlabs.net`): <!-- noqa: account-id - run provenance, account rotates -->

| Phase | State | Run ID / SHA |
|---|---|---|
| state backend | bootstrapped | base run 34396955442 |
| base | applied, success 19:45:34Z–19:48:57Z | 34396955442 (branch `18a4205`) |
| management | applied, success 19:49:39Z–20:10:57Z; re-applied 22:06Z–22:07Z for the widened verifier/reaper policy | 34397369089 (branch `18a4205`); 34410469157 (branch `4364d4a`) |
| hub cluster | EKS `k8-platform-mgmt` live | management runs above |
| spoke cluster | EKS `k8-platform-services` ACTIVE, node group `k8-platform-services-default` ACTIVE, 2 Ready nodes via the relay | oracle RUN_ID `build6-2220` |
| gate 1 (platform-cluster-claim) | synced by `kubectl patch` at the explicit SHA; XPlatformCluster `platform/platform` Ready, nodegroup `platform-78032583fa77` Ready, 15 min | `.status.sync.revision` = `bc1cbb6fe27b976dee0b4e86953114481ca15d51` |
| gate 2 (spoke-access) | synced at the same explicit SHA; registration Secret `platform-spoke` complete (full ADR-0010 contract) in the first 30 s; XSpokeAccess Ready=True 4m10s, XPlatformCluster Ready=True 20m, 20:37:02Z | revision confirmed = `bc1cbb6` |
| Argo CD apps | every Application Synced/Healthy except `workload1-cluster` (OutOfSync by design); all report synced revision `96279fd` after the post-merge auto-sync, incl. the new `spoke-storage` Application | `96279fd1d5a6fb5d852671e0211aa8c3e7fc9404` |
| spoke storage | `aws-ebs-csi-driver` addon ACTIVE `v1.65.0-eksbuild.2` under IRSA role `k8-platform-k8-platform-services-ebs-csi`; `ebs.csi.aws.com` registered; StorageClass `gp3 (default)`; 3/3 monitoring PVCs Bound; `spoke-observability-kube-prometheus-stack` and `spoke-observability-loki` Healthy | composition delivered at `96279fd` |
| oracles | pass=25 skip=3 fail=0 checks=28, 22:20Z–22:28Z; suite still exits 3 on the expect-full gap (`kp-lc5`); 3 structural skips (`kp-ug3`) | RUN_ID `build6-2220`, `LIVE_CLUSTER=k8-platform-services`, `LIVE_PROFILE=full`, mutating |
| live-verify | success (`profile=full`), evidence record emitted | 34412419016 (`main` @ `96279fd`) |
| live-evidence gate | success; the fail-closed gate reads the evidence as satisfying | 34414013044 (`main` @ `96279fd`) |
