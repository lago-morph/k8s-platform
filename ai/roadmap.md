# Roadmap — from "built" to "done"

Owner-set plan, 2026-09-08, revised 2026-09-09. This file is the authority
on *what comes next and why*; `ai/handoff.md` holds *verified current
state*; the beads issue graph (`bd ready`, skill `.claude/skills/beads/`)
holds the *individual tasks*. When they disagree, fix the stale one rather
than hybridizing.

## Where this starts

Five consecutive clean builds have proven the substrate from committed
source with zero manual steps (`SUBSTRATE-READINESS.md`). The phase-5
identity work (Keycloak federated to Cognito, kubectl federated to
Keycloak) is built and merged but can only be *proven* on a fresh
Keycloak database, so readiness rows 10 and 11 still read `pending
clean-build verification`. The repository was idle from 2026-07-06 to
2026-09-08. The owner's frustration is exact: the platform has never been
seen working end to end as one thing.

## The MVP criterion (owner, 2026-09-09)

The MVP is **testable**, not tenant-friendly. A scenario counts as
testable if every step is either self-service or *"raise a ticket outside
the system, an admin does something documented, continue"*. An admin
creating a tenant's database on request is fine; a tenant who then cannot
reach that database is not.

Consequences:

- A gap that blocks end-to-end testing even with a ticket is fixed now.
- Every other new capability, however obvious the gap, goes into the
  **v2.0 bucket** (beads epic labelled `v2.0`) and is not built early.
- Step 6 re-evaluates the bucket and decides whether a v1.1 happens before
  the refactor.
- Security fixes are immediate only when exploitable from the public
  internet; all other security hygiene is step 6 or v2.0.
- The admin is assumed to have direct VPC access (their own VPN). A
  platform-provisioned VPN is v2.0.

## The steps

| Step | Goal | Exit condition | Executed by |
|---|---|---|---|
| 1 | Small cleanups from the 2026-09-08 re-verification | PR #262 merged | Fable (done) |
| 2 | Replan: this file, a short handoff, beads seeded, hooks | PR #263 merged; `bd ready` shows step 3 | Fable |
| 3 | **Feature complete**: clean build #6, every classed defect fixed and minimally tested, the three testability gaps documented | Definition below met, evidence by run ID | Opus, beads |
| 4 | Admin and tenant documentation of the design **as it is**, gaps named honestly | Docs site pages `stable` | beads-assigned models |
| 5 | Pass-1 end-to-end tests in a hold-out repo (admin, tenant, end-user), run from an EC2 instance inside the VPC; fix what they find | Suite green against a clean build, with v2.0 gaps as expected findings | beads-assigned models |
| 6 | **Cleanup**: known non-blocking issues, CI and static hygiene, non-internet-exploitable security hygiene; re-evaluate the v2.0 bucket, decide on a v1.1 | Bucket triaged; v1.1 decided | owner + models |
| 7 | Refactor in small steps: clearer structure, defined interfaces, modularity | Each step keeps the e2e suite green | beads-assigned models |
| later | Retrospective harvest, then the blog series | — | owner decides when |

Order matters: no refactoring before the implementation is proven and
documented, because the step 5 suite is the safety net that makes
refactoring cheap. Retrospectives stay unharvested until the owner asks.

**Steps are planned one at a time.** Only step 3 is planned in detail.
Each later step opens with a collaborative planning session with the
owner (a `gate` bead every child depends on); the beads under steps 4 to
7 today are sketches labelled `sketch` and are not the plan.

## Definition of "feature complete" (step 3 exit)

Owner's words: *all open issues that do not involve new features are
resolved, and anything installed that is exhibiting errors is fixed and
at least minimally tested.* Operationally:

1. **Kyverno removed first.** It is a v2.0 item (node memory in the dev
   account; its fail-closed webhook wedged the hub). The removal touches
   management Terraform, so it lands on the build #6 branch before the
   base/management dispatch, where live-verify evidence is produced
   anyway. `policies/` stays with a README.
2. **Build #6 evidence.** Rows 10 and 11 in `SUBSTRATE-READINESS.md`
   flip on a from-scratch build of `main` on a rotated account, with the
   federation oracle recorded by run ID (`ai/recipes/clean-build-6.md`).
3. **Every issue classed `defect` below is resolved** with clean-build
   or oracle evidence, not a hand-fix.
4. **Every installed component is healthy**: the finished-platform
   inventory shows nothing non-green except rows it marks *by design*,
   and each fix ships with a test at the closest layer.
5. **The three testability gaps are documented** (no new code): the
   admin access page (cluster access from the VPC, the Argo CD password,
   the platform facts); the CI-dispatch build path declared the supported
   human build with the workstation runbook demoted to unverified; the
   database ticket runbook (admin places XDatabase plus a PushSecret to
   the tenant's Secrets Manager path, tenant consumes with an
   ExternalSecret).

## How a human builds it today (honest assessment, 2026-09-09)

Two "Run workflow" clicks in GitHub Actions (`terraform-test.yml`: base,
then management, action apply-and-verify) with state, domain and test
credentials derived automatically; then two gate syncs from any machine
with cluster access (`argocd app sync` or one `kubectl patch` each).
Every clean build used this path. There is no CLI and no single build
script; `scripts/` holds read-only diagnostics. The copy/paste Terraform
runbook in the docs site has never been executed by a person. The SSM
relay exists only because the sandbox cannot reach the API servers; an
admin on the VPN does not need it.

## Classification of open issues

Class key: **defect** = step 3; **docs** = step 3, documentation only;
**cleanup** = step 6; **v2.0** = the bucket; **owner** = deferred by
explicit ruling.

| ID | One line | Class | Why |
|---|---|---|---|
| Rows 10/11 | Keycloak↔Cognito federation; kubectl via Keycloak | defect (unproven) | The point of build #6 |
| OI-2026-06-11-2 | Kyverno OOM / unpullable cleanup jobs / fail-closed webhook | v2.0 (remove now) | Owner: dev-account node memory; removal is the first step 3 bead |
| OI-2026-06-11-3 | Spokes ship no CSI driver / StorageClass; observability pair Pending | defect | Installed and erroring |
| OI-2026-07-06-5 | No documented access path | docs | Admin page (VPC access, Argo CD password, facts); end-user path proven by build #6; tenant self-service is v2.0 |
| OI-2026-07-06-4 | No human-executed bring-up | docs + owner | CI-dispatch path declared supported; a person runs it (can double as the step 5 admin scenario) |
| OI-2026-07-06-1 | XDatabase has no cross-cluster consumption contract | docs (ticket runbook) + v2.0 (self-service) | Tenants cannot place XDatabase on the hub; admin ticket + PushSecret + ExternalSecret works today with no new code |
| OI-2026-06-06-3 | XDatabase `<xr>-master` Secret not GC'd | defect | Confirm on build #6, then compose with an owner reference |
| OI-2026-06-07-7 | resourceRefs ⇒ AccessDenied spike unconfirmed | defect (verify) | Build #6 provides the XR |
| OI-2026-07-06-3 | ClusterRoleBinding guard audit-only | v2.0 | Goes with Kyverno; all 11 policies are audit-only today and hub-only |
| OI-2026-07-06-2 | Cross-tenant secret readability | v2.0 (security) | Per-tenant SecretStore + IRSA role; not internet-exploitable |
| OI-2026-06-08-1 | Crossplane role `Resource:"*"` not tightened | cleanup (security hygiene) | Needs a teardown-rebuild window |
| OI-2026-06-11-4 | CI-harness hardening R2/R3/R4 + `pull_request` trigger | cleanup | LESSONS S4 |
| #22 leftovers | shellcheck, actionlint, python lint | cleanup | Audit-before-enforce |
| OI-2026-06-07-6 | Static assertions masquerade as tests (umbrella) | superseded by step 5 | Not a single bug |
| OI-2026-06-07-8 | Jentic capstone | owner | Revisit after 2026-09-20 |
| LESSONS S2 | Scoped sandbox credentials | cleanup (security hygiene) | Mechanism decision owed |
| v1 naming residue | `platform-cluster-claim`, `claim-*` chainsaw dirs | step 7 | Rename during the refactor |
| VPN, public API endpoints off, tenant self-service onboarding | — | v2.0 | Owner rulings 2026-09-09 |

Resolved entries stay in the archived register for the rationale record.

## Installed components: current health expectations

| Component | Expected today | After step 3 |
|---|---|---|
| hub Kyverno | removed (kp-2al.17); no `kyverno` namespace or pods | removed (v2.0); policies dormant in `policies/` |
| spoke observability (prometheus, alertmanager, loki) | Synced/Healthy since clean build #6 (composed EBS CSI addon + default `gp3` StorageClass; 3/3 PVCs Bound) | unchanged — the Bound-PVC oracle landed with it (spoke-storage check, RUN_ID `build6-2220`); class-then-PVC ordering is still `pending clean-build verification` |
| `workload1-cluster` gate | OutOfSync by design | unchanged (fan-out exercised in step 5) |
| Keycloak realm broker | present since clean build #6 (imported on the fresh Keycloak DB) | achieved — federation oracle PASS on build #6, RUN_ID `build6-2220` (rows 10/11 DONE) |

## Step 5 shape (decided 2026-09-09)

Tests run from a small EC2 instance inside the base VPC, reached through
Session Manager, as plain scripts: a person debugs by opening a shell and
running the same script; an agent triggers it with one SSM command; output
lands in the state bucket. No GitHub self-hosted runner unless run-ID
evidence later proves worth the extra moving part. The hold-out repo's
charter (`planning/scenario-corpus/charter.md`) gains the in-VPC
assumption, the ticket criterion, and expected-finding scenarios for v2.0
gaps.

## How the plan is tracked

Beads (`bd`, prefix `kp`) holds the task graph; Dolt data lives on the
branch `beads-dolt-data` of this repository (plus Dolt's own
`__dolt_remote_info__`; neither is a code branch —
`ai/beads-dolt-git-remotes.md` explains why a branch and how sync works).
Hooks, not instructions, keep it in sync: session start installs the
pinned `bd` and pulls; every assistant turn end, every compaction, and
every `git push` push unpushed beads, and a failed beads push blocks the
code push. Epics mirror the steps above plus the v2.0 bucket; the step 3
epic carries the build #6 recipe at a level a follow-the-recipe agent can
execute without improvising. The `beads` skill records the working
habits and may be improved in place by any session, with a note to the
owner.

## Model plan

Fable for steps 1 and 2 (planning, judgment-heavy). Opus for step 3 (a
recipe with explicit stop conditions). From step 4, beads assigns tasks
to models by kind. Recommendation only: have Fable review the build #6
retrospective before step 4 begins, since every prior first live
exercise found one to four new defects.

## Time-boxed external item

Jentic's hosted execution ends 2026-09-20. Native GitHub MCP tools cover
dispatch and logs; only workflow-file writes still need the bridge (the
step 6 CI-hardening bead). Decision deferred by the owner: revisit after
that date.
