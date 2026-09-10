# Session Handoff — k8s-platform

Verified state only (run IDs, SHAs, PR numbers, account shape). Open work
and next actions live in beads: `bd ready`. The plan and the definition
of "feature complete" live in `ai/roadmap.md`. **The ordered plan for
step 3 — which beads need no AWS account, which need a live platform,
which are the owner's alone, and what order holds an account for the
shortest time — is in the epic: `bd show kp-2al`.** Keep this file short:
replace stale facts, never append narrative. The pre-2026-09-08 handoff
is archived verbatim at `docs/archive/handoff-2026-09-08.md`.

## Verified 2026-09-10

| Fact | Value | Evidence |
|---|---|---|
| `main` | `65778961ee4ea25fd8681b4177f1e4dca06d9ac4` (PR #269, ADR-0018) — the SHA build #8 is being built from | `git log` |
| Clean builds proven | seven (#1–#7); rows 1–9 evidenced 4×–6× | `SUBSTRATE-READINESS.md` |
| Rows 10/11 | DONE on clean builds #6 and #7 (federation + federated kubectl; RUN_IDs `build6-2220`, `build7-0152`); build #6's not-a-single-SHA caveat retired by #7 on the platform half | `SUBSTRATE-READINESS.md` |
| AWS account | ROTATED to `439891535995`, us-east-1 — a genuinely NEW account, not a reset one: no state bucket, no lock table, no resources | creds probe 34506884919, `scripts/whereami.sh` | <!-- noqa: account-id - run provenance, account rotates -->
| GHA secrets | valid for the new account | creds probe 34506884919 (creds 3/3 naming the account above, zone 4/4 `<account-id>.realhandsonlabs.net.`, state-backend 0/2 — the RED that is the documented pass signal on a fresh account) |
| Owner ruling 2026-09-10 | this account is spendable: the owner will create a BRAND-NEW account for the human bring-up (`kp-2al.10`), so build #8 does not consume what that bead measures. Leave this one cleaned up | owner, this session |
| CI dispatch from the sandbox | native GitHub MCP `actions_run_trigger` + `get_job_logs` work | runs 34421097160 / 34421376617 / 34428165725 |
| Jentic bridge | still works; hosted execution ends 2026-09-20; only needed for `.github/workflows/**` writes | `mcp__Jentic__list_credentials` deprecation notice |
| Sandbox git push | branch create + force-with-lease OK; non-branch refs and branch deletes HTTP 403 | probes 2026-09-08 (`ai/environment.md` §2) |
| Leftover | branch `probe-delete-me-ref-test` on origin awaits owner deletion (bead `kp-2al.31`) | — |
| Latest evidence on the branch | live-verify success at PR #267's head `5ac400c`, and the fail-closed live-evidence gate green at the same SHA | 34430738213, 34432226978 |
| PR #267 | open, mergeable, unit tests green — carries build #7's evidence, the teardown fixes, the harness fixes and the corrected bring-up page | `gh` PR view |
| PR #270 | open — step 3 Phase A: `kp-du3`, `kp-2al.28` (static half), `kp-2al.24`, `kp-2al.22`, the teardown runbook (`kp-2al.30`) and the database scenario-ready check (`kp-2al.16`). Touches no live-evidence-gated path | PR #270 |
| Account after this session | expected to ROTATE. Assume nothing until `scripts/whereami.sh` says otherwise; a new account means new GHA secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`) | — |

## Environment state

The account rotates between sessions. Assume every phase `not applied`
until `scripts/whereami.sh` and the live API prove otherwise. When a
build is in progress, record the chain here as facts (probe → base →
management → gate SHAs → oracle RUN_ID → live-verify run ID) and move
them into `SUBSTRATE-READINESS.md` when the build completes.

Build #8 state as verified 2026-09-10 (NEW account, us-east-1 — a
genuinely fresh account, not a reset one; built entirely from `main`
`65778961ee4ea25fd8681b4177f1e4dca06d9ac4`, single SHA for probe, base,
management and BOTH gate syncs):

| Phase | State | Run ID / SHA |
|---|---|---|
| probe (`test`/`test-e2e`) | conclusion failure BY DESIGN — creds 3/3, zone 4/4, state-backend **0/2** (bucket and table absent before bootstrap). This is the RED the bring-up page predicts for a fresh account, and the first build able to demonstrate it: #7 came out green because its teardown left the backend behind | 34506884919 |
| base | success, apply 17:15:04Z–17:17:19Z, **3m21s** (page reference 3m23s) | 34506951822 |
| management | success, apply 17:18:20Z–17:38:35Z, **20m15s**; `[management] e2e-verify` green and `[management] argocd-url` green (it went red on #7) | 34507332116 |
| hub cluster | EKS `k8-platform-mgmt` ACTIVE 17:32:11Z (control plane ~14 min); node group ACTIVE 17:35:03Z; 4 running instances at that point (3 hub + relay) | operator measurement |
| bootstrap fan-out | 8 hub Applications; the three transient OutOfSync ones (`crossplane-resources`, `keycloak-db`, `keycloak-secrets`) settled by 17:46:38Z, ~8 min after management — as the page's F4 correction states | operator measurement |
| gate 1 (platform-cluster-claim) | patched 17:47:00Z at the explicit SHA; `.status.operationState.phase=Succeeded`, `syncResult.revision` = that SHA, `sync.status=Synced` — the kp-2al.24 corrected check, exercised live | `65778961ee4ea25fd8681b4177f1e4dca06d9ac4` |
| gate 1 duration | four facts published 17:57:42Z, node group Ready 18:00:48Z — **13m48s** from sync, BELOW the page's stated 15–25 min range (third data point: 15 on #6, 24 on #7, 13.8 on #8) | operator measurement |
| gate 2 (spoke-access) | patched 18:01:11Z, same SHA; `operationState.phase=Succeeded` at that SHA; registration Secret `platform-spoke` carried all six `k8-platform.io/*` annotations within 40 s; XSpokeAccess Ready 18:06:33Z, **5m22s** | `65778961ee4ea25fd8681b4177f1e4dca06d9ac4` |
| Argo CD apps | 17 Applications, all Synced/Healthy except `workload1-cluster` (OutOfSync by design), converged 18:05:18Z. Live names are exactly the `spoke-*` set plus `hub-observability-alloy` — live confirmation of the kp-2al.22 inventory correction | operator measurement |
| composites | 5: `xplatformcluster`, `xdatabase/keycloak-db`, 2× `xplatformsecret` all Synced+Ready; `xspokeaccess` Ready at 18:06:33Z | operator measurement |
| behavioural gate | `hello.platform.<domain>` HTTP 200, body `hello from the k8-platform platform-services cluster`; Argo CD HTTP 200 | operator measurement (TLS validated against the intercepting egress gateway, not the ACM chain) |
| kp-2al.28 live confirmation | on `XPlatformCluster platform/platform`: `.spec.resourceRefs` EMPTY, `.spec.crossplane.resourceRefs` = 16, and the fixed `scripts/crossplane-trace.sh` printed `resourceRefs (16 total)` with per-resource conditions and `compRef=platform-cluster-aws` | operator measurement 17:48:32Z |
| kp-2al.8 before-state | `keycloak-db` uid `1b25b14f-56f9-4bb8-a473-b66a3c525f99` and `keycloak-db-master` uid `e6236c2f-4f55-44c3-98a0-54c9f7af14be`, BOTH ownerReferenced to `Instance/keycloak-db-41f61ab935ae` uid `35017b49-870a-4414-8830-06d1861c0491` | operator measurement 18:06Z |
| not verified on this build | **Keycloak OIDC discovery — not attempted against the right host.** The operator probed `keycloak.platform.<domain>`, which the platform never publishes; the SSO host is `auth.platform.<domain>` (the bring-up page's verification check 4 names it, and its A record was present in the zone by 18:19Z alongside `hello.platform`, `grafana.platform` and `argocd.management`). By the time the wrong hostname was identified the teardown had begun, so the check was not run. This is an operator error, not a platform or documentation gap. The federation oracles and live-verify were likewise not dispatched (rows 10/11 are already DONE 2×, and this account's remaining budget went to the teardown validation). Also unverified: Argo CD browser sign-in, direct ACM-chain validation from the sandbox | — |

Build #7 state as verified 2026-09-10 (same account as build #6,
`801822495028`, us-east-1 — emptied to nothing after build #6 and rebuilt <!-- noqa: account-id - run provenance, account rotates -->
from scratch; the bring-up was executed by a fenced agent allowed to read
only `docs/site/how-to/build-the-platform-from-nothing.md`):

| Phase | State | Run ID / SHA |
|---|---|---|
| teardown before it | management destroy 13 min, then base destroy; account verified empty (no EKS clusters, 0 load balancers, 0 RDS instances, no `k8-platform-*` IAM roles besides the hub's) | 34419405234, 34420560366; mid-teardown IAM fix `6e84258` applied by 34418948661 in 48 s |
| platform SHA | `main` `3298e70f614d793f040ea4d6b97c4455cfe028b9` — probe, base, management and BOTH gate syncs | `git log` |
| harness SHA | branch, NOT `3298e70`: live-verify ran ref `bf520ba353d4544339175076ea66dacbf49d2bcc`; the two oracle runs ran the same branch harness at or before that commit (the guard-check defect `bf520ba` fixes was still failing on them) | `git log` |
| probe (`test`/`test-e2e`) | green in 19 s (creds 3/3, zone 4/4, state-backend 2/2) — green where the page documents red, because the teardown left the state backend behind | 34421037502 (`main` @ `3298e70`) |
| state backend | survived the teardown; not re-bootstrapped | probe 34421037502 |
| base | applied, success, 2m55s | 34421097160 (`main` @ `3298e70`) |
| management | applied, success, 17m24s (single apply, no re-apply) | 34421376617 (`main` @ `3298e70`) |
| hub cluster | EKS `k8-platform-mgmt` live | management run above |
| spoke cluster | EKS `k8-platform-services` live, node group Ready | gate 1 below; relay oracle PASS |
| gate 1 (platform-cluster-claim) | synced at `3298e70`; XPlatformCluster `platform/platform` published its four facts and the node group reached Ready, ~24 min from sync | `3298e70f614d793f040ea4d6b97c4455cfe028b9` |
| gate 2 (spoke-access) | synced 01:20:40Z at the same SHA; registration Secret `platform-spoke` present at 11 s with all six `k8-platform.io/*` annotations as documented; XSpokeAccess Ready ~6m10s | `3298e70f614d793f040ea4d6b97c4455cfe028b9` |
| IdP ordering | `identityproviderconfig/platform-5183a6d2c254` (owner `XPlatformCluster/platform`) `Ready=True reason=Available` 01:13:50Z, composite 01:14:17Z — both before gate 2 synced at 01:20:40Z | operator measurement |
| Argo CD apps | 17 Applications, all Synced/Healthy except `workload1-cluster` (OutOfSync by design) | operator measurement |
| endpoints | hello HTTP 200 in 0.50 s, body `hello from the k8-platform platform-services cluster`; Argo CD HTTP 200; Keycloak OIDC discovery HTTP 200 with the expected issuer | operator measurement (TLS validated against the intercepting egress gateway, not the ACM chain) |
| composites | 5 Synced=True Ready=True: `xplatformcluster`, `xspokeaccess`, `xdatabase/keycloak-db`, 2× `xplatformsecret` | operator measurement |
| spoke storage ordering | StorageClass `gp3 (default)`/`ebs.csi.aws.com` age 6m57s vs monitoring PVCs 6m50s/6m22s/6m17s — class before every PVC, all 3 Bound on gp3, no retroactive assignment (`kp-2al.19`) | operator measurement |
| oracles | `build7-0135`: pass=27 skip=0 fail=2 (federation kubectl leg; AppProject destination guard). `build7-0152`: pass=28 skip=0 fail=1 (destination guard only; federation PASSED, `username=kc:oracle-build7-0152@federation-oracle.invalid groups∋kc:k8s-viewers`). Zero skips is new (`kp-ug3`). Destination-guard failure = CHECK defect, fixed in `bf520ba` (`kp-2al.27`); federation failure = association warm-up window (rejected ~01:43Z, accepted ~01:54Z) | `LIVE_CLUSTER=k8-platform-services`, `LIVE_PROFILE=full`, mutating, harness `bf520ba` |
| live-verify | conclusion success (`profile=full`), evidence artifact 10133798389 uploaded 02:22:21Z | 34428165725 (ref `bf520ba`) |
| not verified on this build | Argo CD browser sign-in (no Chromium egress; credential checked via the `argocd` CLI), direct ACM-chain validation from the sandbox, the `kp-lc5` expect-full figure (not recorded either way), the fail-closed live-evidence gate (no gate run recorded for this build — only the producer, 34428165725), and a HUMAN executing the page on a FRESH account (`kp-2al.10` open; the page keeps `status: contract`) | — |
