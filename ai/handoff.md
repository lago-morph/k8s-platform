# Session Handoff — k8s-platform

Verified state only (run IDs, SHAs, PR numbers, account shape). Open work
and next actions live in beads: `bd ready`. The plan and the definition
of "feature complete" live in `ai/roadmap.md`. **The ordered plan for
step 3 — which beads need no AWS account, which need a live platform,
which are the owner's alone, and what order holds an account for the
shortest time — is in the epic: `bd show kp-2al`.** Keep this file short:
replace stale facts, never append narrative. The pre-2026-09-08 handoff
is archived verbatim at `docs/archive/handoff-2026-09-08.md`.

## Build #10 — the owner's bring-up, 2026-11-27

The owner executed `docs/site/how-to/build-the-platform-from-nothing.md`
on a fresh account (`637423636571`, us-east-1) from `main` <!-- noqa: account-id - run provenance, account rotates -->
`35eee974c79fbe0c49359352f44a03aced3ddce4` (kp-2al.10, closed). The
account has since **timed out**; nothing is running anywhere.

| Fact | Value |
|---|---|
| Ops box `apply` | 45939416156 |
| base / management | 45940909805 / 45941267372 |
| driver | `k8p-bringup.sh` BRING-UP COMPLETE 06:57:31Z, gate SHA `35eee97`, hello 200 |
| Session Manager | browser shell opened by a person from the console: `uid=1001(ssm-user)` in the `k8-platform` checkout |
| Live verify (old producer) | 45955338643: `pass=17 skip=12 fail=0` |
| the 12 skipped, owner-run | RUN_ID `owner-1127-0715`, mutating, harness `35eee97`: 12/12 PASS, 308 s |
| Live verify (new producer, PR #278) | 45959888007 at `ee427fc`: `pass=29 skip=0 fail=0`, 1m36s; 45960453458 after #277 merged: `pass=29 skip=0` |
| shape | hub 3× t3.medium, spoke 2× t3.medium on Kubernetes 1.32 (built before #277) |
| finding | console URL region masked as `***` (kp-2al.36) |

Merged since: PR #277 (`ceccbd8`, 2× m5.large, node type and version
single-sourced, spoke 1.35; Live-evidence gate red by owner exception,
kp-ifh) and PR #278 (`738e12a`, Live verify full verdict). Neither the
m5.large shape nor spoke 1.35 has run on a build yet.

## Environment state

The account rotates between sessions. Assume every phase `not applied`
until `scripts/whereami.sh` and the live API prove otherwise. When a
build is in progress, record the chain here as facts (probe → base →
management → gate SHAs → oracle RUN_ID → live-verify run ID) and move
them into `SUBSTRATE-READINESS.md` when the build completes.

No account is live (2026-11-27). Build #10 ran on `637423636571`, which <!-- noqa: account-id - run provenance, account rotates -->
has timed out; build #9's `851725259254` is gone too. Build records are <!-- noqa: account-id - run provenance, account rotates -->
in `SUBSTRATE-READINESS.md`.

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

Build #8 TEARDOWN, executed 2026-09-10 18:11Z-19:12Z as a FENCED
validation of `docs/site/how-to/tear-the-platform-down.md` (ADR-0018):
the agent was given that page and nothing else from this repository.

| Item | Result |
|---|---|
| account end state (verified by the operator, not only by the agent) | 0 EKS, 0 load balancers, 0 RDS, 0 running EC2, 0 EBS volumes, 0 non-default VPCs, 0 NAT gateways, no `k8-platform-*` IAM roles, state bucket and lock table both absent |
| destroy runs | management 34516300481 (13m43s), base 34517977976 (1m36s) |
| findings | 15; 14 folded into the page (commit 9829c1a), 1 rejected on triage |
| the two serious ones | stage order was wrong — Argo must be stopped BEFORE the LoadBalancer Services or a THIRD NLB is created; and ApplicationSets were unmentioned, though nine of seventeen Applications regenerate about a second after deletion |
| the expensive one | three `available` gp3 volumes totalling 22 GiB survived a teardown that passed every check the page had. The operator deleted them; the page now removes the claims and checks `describe-volumes` |
| rejected on triage | the surviving Route53 hosted zone is PRE-EXISTING (the account ships with it and the build discovers it); deleting it would break the next bring-up. The page says so rather than removing it |
| `kp-2al.8` settled | both `keycloak-db` Secrets were garbage-collected when their owning RDS Instance MR went; the OI-2026-06-06-3 defect does not exist on this stack. UIDs in the bead |
| fence integrity | the agent reported it read only the page, but that a catalogue of repository skill descriptions was auto-injected into its context. Weaker isolation than build #7's; every correction traces to live output it observed, not to that catalogue |

Build #7 (2026-09-10) is recorded in full in `SUBSTRATE-READINESS.md`.
