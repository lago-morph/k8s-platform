# ADR: MVP is testable-not-friendly: the ticket criterion, the v2.0 bucket, and one-step-at-a-time planning gates

- **ID**: ADR-5f512dc5cf
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-09-09
- **Source retrospective**: ../2026-09-09-263.md
- **PRs covered**: #263

## Context

The platform has five clean builds of the substrate but has never been seen working end to end, and the published design has gaps a real tenant would hit at once (no tenant path to request a database, no cross-cluster credential contract, operator-mediated onboarding). Left to itself the agent proposed a five-way gap triage and seeded detailed beads for steps that had not been planned, which the owner rejected: the first pass must prove the design as written, gaps must not pull new features forward, and steps are planned one at a time in a collaborative session.

## Decision

A scenario counts as testable when every step is self-service or 'raise a ticket, an admin does something documented, continue'; anything not blocking end-to-end testing goes into a v2.0 bucket re-evaluated in the cleanup step, and each step is planned in detail only in a collaborative session gated by an owner-assigned bead.

Operationally: gaps that block testing even with a ticket are fixed now (in this session they were all documentation: an admin access page, the CI-dispatch path declared the supported human build, the database ticket runbook); every other capability is a `feature` bead under the v2.0 epic; step 6 (cleanup) re-evaluates the bucket and may declare a v1.1 before step 7 (refactor); each step epic has a GATE decision bead assigned to the owner that every child depends on, pre-written beads carry the label `sketch`, and any step that uses a provisioned AWS account gets an owner bead to provision it that blocks the first AWS-using task.

## Alternatives considered

- **Fix gaps as scenarios expose them** — makes the platform usable sooner but re-opens the failure mode the repository's own lessons register documents (features before proof, hand-fixes counted as progress); rejected by the owner.
- **A five-way triage rule (documentation, implementation, requirements, scenario, gap) enforced by a claim-blocking hook** — proposed by the agent; the owner preferred the simpler criterion and no decision tree.
- **Plan all steps in detail up front** — what the agent did by default; rejected because the owner had not thought about steps 4 and 5 and detailed content presupposed decisions not yet made.

## Consequences

Easier: the definition of "feature complete" is a short checklist; new gaps have one destination; the owner's decisions are made at the right time with the previous step's evidence in hand. Harder: the platform stays unusable by a real tenant until at least step 6; sketch beads sit in the graph and must not be worked; every later step begins with a synchronous session. Accepted trade-off: slower usability for a proven baseline and a safety net (the step 5 suite) before any refactor.

## References

- [`../2026-09-09-263.md`](../2026-09-09-263.md) — the source retrospective.
- `ai/roadmap.md` — the criterion, the steps, and the classification table; `.claude/skills/beads/SKILL.md` — the rules as agents read them.
- Beads: gate beads `kp-cm3.5`, `kp-e5n.9`, `kp-zab.3`, `kp-yif.5`; v2.0 epic `kp-caz`; account bead `kp-2al.18`.
- PR the decision was made in: #263.
