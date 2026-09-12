# Session Handoff — k8s-platform

Verified state only (run IDs, SHAs, PR numbers, account shape). Open work
and next actions live in beads: `bd ready`. The plan and the definition
of "feature complete" live in `ai/roadmap.md`. **The ordered plan for
step 3 — which beads need no AWS account, which need a live platform,
which are the owner's alone, and what order holds an account for the
shortest time — is in the epic: `bd show kp-2al`.** Keep this file short:
replace stale facts, never append narrative. The pre-2026-09-08 handoff
is archived verbatim at `docs/archive/handoff-2026-09-08.md`.

## Build #9 (`kp-2al.34`) — state at 2026-09-12

The ops box drove a from-scratch build on a NEW account
(`851725259254`, us-east-1; nothing in it but the hosted zone). Branch <!-- noqa: account-id - run provenance, account rotates -->
`claude/vibrant-newton-rtrlbw`, PR open against `main`.

| Fact | Value | Evidence |
|---|---|---|
| platform SHA | `main` `b41f48cdc0e7a532da4c69305d41133bf822e541` for probe, base, management and BOTH gate syncs | driver log on the box (`gate SHA — b41f48c…`, both operations `Succeeded` at it) |
| ops box + scripts | the feature branch: `31c812a` (workflow fix, written through jentic) → `434c71d` → `a8553d6`/`b9e84bf` (settled-state check) → `9011d56` (Route53-resolved endpoint check) | `git log` |
| probe | 34672814841, red by design: creds 3/3, zone 4/4, state-backend 0/2 | run log |
| Ops box `apply` | 34673149665 (2m18s, first green self-test ever) and 34673716297 (the re-apply for the IAM change, 45 s; self-test again green, instance not replaced) | run logs; SSM commands `ca3a29a5…`, `5181b4d2…` |
| base | 34673406430, success, 3m14s | run |
| management | 34673599867, success, 18m42s | run |
| driver stages | management detected 896 s after the driver asked; `crossplane-resources` settled 176 s; gate 1 14m31s; gate 2 4m00s; converged 4m47s; first pass STOPPED on the endpoint (negative DNS cache, see below); re-run at `9011d56` → `BRING-UP COMPLETE` in 2 s; `k8p-status.sh` ALL GREEN, exit 0 | `/var/log/k8p-bringup{.1,,.2}.log` on the box |
| endpoints | hello HTTP 200 in 0.47 s with the expected body (sandbox) and 200 pinned to the Route53 target (box); Argo CD HTTP 200 from both | operator measurement 05:37Z–05:42Z |
| Live verify | **RUN_LIVE**, profile `full`, dispatched 05:40:16Z on `main` — LIVE_RESULT | run |
| spoke access from the sandbox | `cloud_user` on the spoke: `auth can-i delete svc -n ingress-nginx` → `no`; `get pvc -A` → `yes` (3 PVCs). The committed platform grants it AdminView only | relay probe 05:44Z |

**Two driver defects found and fixed on this build** (both optimistic
direction, both with red-first unit tests, both re-verified live):

| Defect | Evidence | Fix |
|---|---|---|
| `check_base` GREEN 46 s into the base apply | certificate ISSUED 04:36:01Z, pool 04:36:02Z; apply wrote state 04:38:33Z | phase checks require the state object present and its DynamoDB lock item absent; probed live: base settled, management held mid-apply (`a8553d6`, `b9e84bf`) |
| `check_endpoint` RED past its 600 s budget on a serving platform | box: `Could not resolve host hello.platform…`; sandbox: 200 at the same minute; `argocd.management` (35 min older) resolved from the box | read the A record from Route53, resolve the alias target's own name, `curl --resolve` (`9011d56`) |

**Account state at handoff: the platform is UP and the ops box is
running. TEARDOWN NOT EXECUTED** — the sandbox's permission mode refused
the deletion commands (Kubernetes deletes, `terraform destroy`, the state
bucket). Owner decision needed: run
`docs/site/how-to/tear-the-platform-down.md` (its stage 2/3 on the spoke
need a spoke admin; the AWS-API fallbacks cover them), then **Ops box →
`destroy`**, then step 7 (delete the backend) so the account is fresh for
`kp-2al.10` — or grant the permission and let a session do it.

Running instances: hub 3× `t3.medium`, spoke 2× `t3.medium`, relay
`t3.nano`, ops box `t3.small` (`i-07ca93c3d6924484f`, us-east-1d).

## Environment state

The account rotates between sessions. Assume every phase `not applied`
until `scripts/whereami.sh` and the live API prove otherwise. When a
build is in progress, record the chain here as facts (probe → base →
management → gate SHAs → oracle RUN_ID → live-verify run ID) and move
them into `SUBSTRATE-READINESS.md` when the build completes.

Build #9 (2026-09-12): every phase APPLIED on `851725259254`; chain in <!-- noqa: account-id - run provenance, account rotates -->
the table above and in `SUBSTRATE-READINESS.md`.

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
