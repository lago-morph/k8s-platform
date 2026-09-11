# ADR: Bring-up status is derived from the world, never from CI's own green checks

- **ID**: ADR-7ccc085c26
- **Status**: Draft (not yet adopted to `docs/decisions/`)
- **Date**: 2026-09-11
- **Source retrospective**: ../2026-09-11-271.md
- **PRs covered**: #270, #271

## Context

The bring-up tooling needs an answer to "is this stage green?" at five points. The
obvious source is the GitHub Actions run that performed the stage — it has a
conclusion, an API, and a checkmark. That source is actively misleading in this
repository, and the evidence is specific: the `[management] argocd-url` step is
`continue-on-error`, so the run reports green while that step's own log says
`FAIL: HTTP 000`. Build #7's run went red on it and build #8's went green, with no
change in what the platform actually did. A tool that trusts the checkmark reports
a healthy platform when the endpoint is unreachable.

The same session produced a second, sharper instance of the class. The ops box's
self-test waited for the SSM agent's `PingStatus` to reach `Online` and then
asserted the bootstrap was complete. The agent registered 19 seconds after boot
while `user_data` was still executing `dnf install`; the self-test reported
`BOOTSTRAP-INCOMPLETE` against a box that was merely still working. `PingStatus`
was being used as a proxy for a fact it does not carry — the two processes run in
parallel. Before that, the gate-sync confirmation had the identical shape: Argo CD's
`.status.sync.revision` answers "which revision is the repo-server serving" and was
being read as "a sync happened at that revision", which it never means.

Three instances, one class: a signal that is cheap to read, adjacent to the fact you
want, and silent about the difference.

## Decision

Every stage-complete question the bring-up tooling asks is answered by a describe
against AWS or a read against the cluster API, never by the conclusion of a GitHub
Actions run or step.

`scripts/opsbox/lib.sh` carries this as a load-bearing design rule stated in the
file — "ASK THE WORLD, NEVER GITHUB" — and it has two teeth. The box holds no
GitHub token at all, so the cheap path is not merely discouraged but unavailable.
And `tests/unit/test_opsbox_bringup.sh` greps the scripts for GitHub API calls and
fails if one appears, so a future edit cannot quietly reintroduce it.

The corollary, applied in the same scripts: when a status field is read, read the
one that carries the fact. Gate syncs are confirmed by
`.status.operationState.phase=Succeeded` together with
`syncResult.revision` matching the requested SHA — the completed operation — not by
`.status.sync.revision`. The ops box's bootstrap is confirmed by
`cloud-init status --wait` plus a marker file the bootstrap itself writes, not by
agent reachability.

## Alternatives considered

- **Read the GitHub Actions run conclusion via the API.** Rejected: demonstrably
  reports green over a failed step by design (`continue-on-error`), and would
  require a GitHub token on the ops box, which is exactly the credential the
  ops-box design (ADR-0500f6e2ce) exists to avoid.
- **Read the run's per-step conclusions rather than the run's.** Rejected: it
  fixes the `continue-on-error` case only, still needs the token, and still answers
  "did a workflow step exit zero" when the question is "does the platform have this
  property". The teardown validation had already shown a page whose every check
  passed over 22 GiB of orphaned EBS volumes.
- **Have the workflow publish a structured status artifact the box reads.**
  Rejected as a second source of truth to keep in sync with the first, and it
  inherits whatever the workflow believed rather than what is true.

## Consequences

Easier: the tooling's answers survive CI changes entirely, and a stage that is
genuinely complete reads as complete even if its workflow was cancelled, re-run, or
never used. The absence of a GitHub token on the box is what makes the
ops-box credential posture coherent rather than partial.

Harder, and knowingly accepted: every check must be written against the real API
surface, which is more code than reading one conclusion field, and the checks need
measured wait budgets because the world becomes true asynchronously after the
workflow finishes (`crossplane-resources` settled roughly eight minutes after
management completed on build #8). Each budget is a number taken from a measured
build and is therefore a maintenance obligation as the platform's timings drift. The
scripts also cannot tell the operator *why* a stage failed — that still means
reading the run's log in the Actions UI, so the workflow log stays part of the
operator's toolkit for diagnosis while never being the source for status.

## References

- [`../2026-09-11-271.md`](../2026-09-11-271.md) — the source retrospective.
- [`./ADR-0500f6e2ce-operator-tooling-runs-on-an-aws-resident-ops-box.md`](./ADR-0500f6e2ce-operator-tooling-runs-on-an-aws-resident-ops-box.md) — the companion decision about where the tooling runs.
- `scripts/opsbox/lib.sh` — the design rule and the per-stage checks.
- `tests/unit/test_opsbox_bringup.sh` — the grep guard that keeps the rule enforced.
- Bead `kp-2al.24` — the gate-sync confirmation defect that first surfaced this class.
- PRs the decision was made in: #270, #271.
