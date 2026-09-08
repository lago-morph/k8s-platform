# Roadmap — from "built" to "done"

Owner-set plan, 2026-09-08. This file is the authority on *what comes
next and why*; `ai/handoff.md` holds *verified current state*; the beads
issue graph (`bd ready`) holds the *individual tasks*. When they disagree,
fix the one that is stale rather than hybridizing.

## Where this starts

Five consecutive clean builds have proven the substrate from committed
source with zero manual steps (`SUBSTRATE-READINESS.md`). The phase-5
identity work (Keycloak federated to Cognito, kubectl federated to
Keycloak) is built and merged but can only be *proven* on a fresh
Keycloak database, so readiness rows 10 and 11 still read `pending
clean-build verification`. The repository has been idle since 2026-07-06.
The owner's frustration is exact: the platform has never been seen
working end to end as one thing.

## The steps

| Step | Goal | Exit condition | Executed by |
|---|---|---|---|
| 1 | Small cleanups from the 2026-09-08 re-verification | PR #262 merged | Fable (done) |
| 2 | Replan: this file, a short handoff, beads seeded, hooks | PR merged; `bd ready` shows step 3 | Fable |
| 3 | **Feature complete**: clean build #6 plus every defect below fixed and minimally tested | Definition below met, evidence by run ID | Opus, beads |
| 4 | Admin and tenant documentation, high-level first | Docs site pages `stable`; access path documented | beads-assigned models |
| 5 | End-to-end tests in a hold-out repo (admin, tenant, end-user); run, fix what they find | Suite green against a clean build | beads-assigned models |
| 6+ | Refactor in small steps: clearer structure, defined interfaces, modularity | Each step keeps the e2e suite green | beads-assigned models |
| later | Retrospective harvest, then the blog series | — | owner decides when |

Order matters: no refactoring before the implementation is proven and
documented, because the e2e suite from step 5 is the safety net that
makes refactoring cheap. Retrospectives are deliberately left
unharvested until the owner asks.

## Definition of "feature complete" (step 3 exit)

Owner's words: *all open issues that do not involve new features are
resolved, and anything installed that is exhibiting errors is fixed and
at least minimally tested.* Operationally:

1. **Build #6 evidence.** Rows 10 and 11 in `SUBSTRATE-READINESS.md`
   flip on a from-scratch build of `main` on a rotated account, with
   the federation oracle recorded by run ID.
2. **Every issue classed `defect` below is resolved** with clean-build
   or oracle evidence, not a hand-fix.
3. **Every installed component is healthy**: the finished-platform
   inventory (`docs/site/reference/finished-platform.md`) shows nothing
   non-green except rows it marks *by design*, and each fix ships with a
   test at the closest layer.
4. **An access path exists**: a person can obtain admin, tenant and
   end-user access by following documentation, with no operator
   hand-grant.

## Classification of open issues

Class key: **defect** = in scope for step 3; **feature** = new
capability, deferred to step 5/6 findings or later; **hygiene** = CI or
tooling improvement, low priority, step 3 stretch; **owner** = deferred
by explicit owner ruling. Rows marked *ratify* are judgment calls the
owner may overturn; work on them starts anyway.

| ID | One line | Class | Step | Why |
|---|---|---|---|---|
| Rows 10/11 | Keycloak↔Cognito federation; kubectl via Keycloak | defect (unproven) | 3 | The whole point of build #6 |
| OI-2026-06-11-3 | Spokes ship no CSI driver / StorageClass; observability pair Pending forever | defect | 3 | Installed and erroring |
| OI-2026-06-11-2 | Kyverno OOM crash-loop; cleanup jobs unpullable; fail-closed webhook | defect | 3 | Fix authored in #227; needs clean-build evidence and the 768Mi question answered |
| OI-2026-07-06-5 | No documented access-acquisition path | defect | 3 | Owner ruling: hand-grants are the defect. Largely delivered by rows 10/11 plus a how-to |
| OI-2026-07-06-4 | No human-executed bring-up verified | defect | 3 (owner runs it) or 5 | Closes only when a person executes the how-to on a fresh account; the e2e admin scenario can be that run |
| OI-2026-06-06-3 | XDatabase `<xr>-master` Secret not GC'd | defect | 3 | Confirm on build #6 via the deletion-cleanup scenario, then compose the Secret with an owner reference |
| OI-2026-06-07-7 | resourceRefs ⇒ AccessDenied spike not confirmed | defect (verify) | 3 | Needs a provisioned XR; build #6 provides one |
| OI-2026-07-06-3 | ClusterRoleBinding escalation: Kyverno guard audit-only | defect (security), *ratify* | 3 | Decision owed: enforce vs narrow the whitelist; fail-closed risk on spokes must be weighed |
| OI-2026-07-06-2 | Cross-tenant secret readability (deterministic names, cluster-wide store) | feature (security design), *ratify* | 5 finding | Requires per-tenant scoping design; step 5's isolation scenario will surface it as an expected finding |
| OI-2026-07-06-1 | XDatabase has no cross-cluster consumption contract | feature | 5 finding | A tenant on a spoke cannot consume a hub-landed Secret; step 5 will document the failure honestly |
| OI-2026-06-08-1 | Crossplane role `Resource:"*"` not tightened | hygiene (security hardening), *ratify* | 6 | Deliberately deferred twice; needs a teardown-rebuild window; pairs with refactoring |
| OI-2026-06-11-4 | CI-harness hardening queue (R2 wait-for-in-flight, R3 kind pin, R4 verifier trigger) | hygiene | 3 stretch | R4 likely = `pull_request` trigger (LESSONS S4) |
| OI-2026-06-07-6 | Static assertions masquerade as tests (umbrella) | umbrella | 5 supersedes | Not a single bug; the e2e suite is the answer |
| OI-2026-06-07-8 | Jentic workflow-integration capstone | owner | deferred | Owner: revisit after 2026-09-20 if still needed |
| #22 leftovers | shellcheck, actionlint, python lint, `pull_request:` trigger | hygiene | 3 stretch | Cheap; the trigger also closes LESSONS S4 |
| LESSONS S2 | Scoped sandbox credentials (no standing admin mutation) | feature | 6 | Mechanism decision owed; the done-contract already bans hand mutation |
| v1 naming residue | `platform-cluster-claim` (file, Application) and `claim-*` chainsaw dirs still carry the retired "claim" vocabulary | hygiene | 6 | Rename during the refactor, when the e2e suite covers the gate |
| chainsaw ASM residue | old handoff claims chainsaw can leak `k8-platform/<uid>` secrets whose MR is gone at trap time | hygiene (verify) | 3 stretch | Check `tests/chainsaw/run.sh` first; drop if stale |

Resolved entries stay in the archived register for the rationale record.

## Installed components: current health expectations

| Component | Expected today | After step 3 |
|---|---|---|
| hub kyverno | pending clean-build verification of the #227 fix | Healthy, limit justified |
| spoke observability (prometheus, alertmanager, loki) | Degraded / Progressing (no storage) | Healthy with a Bound-PVC oracle |
| `workload1-cluster` gate | OutOfSync by design | unchanged (fan-out exercised in step 5) |
| Keycloak realm broker | absent on a live realm (IGNORE_EXISTING) | present on build #6, federation oracle PASS |

## How the plan is tracked

Beads (`bd`) holds the task graph; Dolt data lives on the branch
`beads-dolt-data` of this repository (`ai/beads-dolt-git-remotes.md`
explains why a branch and how sync works). Hooks, not instructions,
keep it in sync: session start installs the pinned `bd` and pulls;
session end and pre-compaction push; a pre-push guard refuses to push
code while beads has unsynced changes. Epics mirror the steps above;
the step 3 epic carries the build #6 recipe at a level a
follow-the-recipe agent can execute without improvising.

## Model plan

Fable for steps 1 and 2 (planning, judgment-heavy). Opus for step 3 (a
recipe with explicit stop conditions). From step 4, beads assigns tasks
to models by kind. Recommendation only: have Fable review the build #6
retrospective before step 4 begins, since every prior first live
exercise found one to four new defects.

## Time-boxed external item

Jentic's hosted execution ends 2026-09-20. Native GitHub MCP tools now
cover dispatch and logs; only workflow-file writes still need the
bridge. Decision deferred by the owner: revisit after that date.
