# ADR: A bring-up's verdict is the committed live suite, not the tool that drove it

- **ID**: ADR-56e14f1165
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-09-12
- **Source retrospective**: ../2026-09-12-274.md
- **PRs covered**: #273

## Context

The ops-box driver (`scripts/opsbox/k8p-bringup.sh`) takes a fresh account
from nothing to a serving platform and ends in one red or green. The bead
that commissioned it (`kp-2al.34`) carried a second design rule beside
"watch the world, not GitHub": the final green must come from
`tests/live/checks/**`, the behavioural oracle the Live verify workflow
already runs, and the scripts must not invent a third opinion about whether
the platform works. Build #9 (2026-09-12) is where that rule became a
concrete shape. The driver's own last stage is a real HTTP 200 from the
hello endpoint, which it needs in order to say its own five stages are done;
it then prints an `ACTION NEEDED` box telling the operator to dispatch Live
verify and read the conclusion. Live verify ran on `main` at
`b41f48c` and passed (run 34676173964, `pass=17 skip=12 fail=0
expect-full-violations=0`, evidence artifact 10292837259), and that run, not
the driver's `BRING-UP COMPLETE`, is what the readiness record cites as the
build's verdict.

The alternative shape, having the box run the live suite itself, was
considered and rejected in the session: the suite runs under a scoped
verifier role assumed with a session tag, writes an unforgeable evidence
record consumed by the push-time live-evidence gate, and was designed to be
run from CI by exactly that identity. Reproducing that on the box would
duplicate the evidence path and give the box credentials it does not need.

## Decision

The final green of a bring-up is the conclusion of the Live verify workflow running tests/live/checks/**; k8p-bringup.sh ends by handing off to it and asserts nothing about the platform beyond the hello endpoint it needs to declare its own stages done.

Concretely: the driver's stage 5 checks convergence of the Application
stack and a 200 from `https://hello.platform.<domain>/`, prints
`BRING-UP COMPLETE`, and then prints the Live verify dispatch instructions.
The bring-up page's step 4 names Live verify's conclusion as "the platform's
own verdict". `SUBSTRATE-READINESS.md` records a build by its Live verify run
ID. The box carries no GitHub token, so it cannot read that run; the operator
reads it in the Actions UI.

## Alternatives considered

- **The box runs `tests/live/run.sh` itself and its exit code is the green.**
  Rejected: the suite's evidence record is meaningful only when produced by
  the scoped verifier role from CI, where the live-evidence gate can find it
  by run ID and SHA. A box-side run would be a second, unrecorded opinion.
- **The driver grows its own verification checklist** (Argo CD 200, OIDC
  discovery, composites Ready, storage Bound) so the operator never needs
  a second click. Rejected as exactly the "third opinion" the bead forbids:
  every check the driver adds is one the suite already has, and two
  implementations of the same assertion drift.
- **Drop the driver's hello check and rely on Live verify alone.** Rejected:
  the driver needs a behavioural signal to know its own stage 5 is done and
  to stop the operator from dispatching Live verify against a platform that
  is still converging.

## Consequences

Easier: one oracle, one evidence path, one place to add a check. The
driver stays small and its unit tests stay about stage detection, not
platform correctness. The readiness record's "by run ID" rule keeps
working unchanged.

Harder: the procedure has one more click, and the operator must read a run
conclusion in a different tab. The box cannot tell the operator the
verdict; if Live verify is red, the diagnosis starts in CI logs, not on
the box.

Accepted trade-off: a duplicate hello check in the driver (it is the one
assertion both need), justified because it gates the driver's own
completion rather than standing in for the suite.

## References

- [`../2026-09-12-274.md`](../2026-09-12-274.md) — the source retrospective.
- [`../2026-09-11-271/ADR-7ccc085c26-bring-up-status-is-derived-from-the-world.md`](../2026-09-11-271/ADR-7ccc085c26-bring-up-status-is-derived-from-the-world.md) — the sibling rule (what the driver may trust for its stages).
- `scripts/opsbox/k8p-bringup.sh` (closing `say_do`), `docs/site/how-to/build-the-platform-from-nothing.md` §4, `.github/scripts/live-verify-run.sh`.
- PRs the decision was made in: #273.
