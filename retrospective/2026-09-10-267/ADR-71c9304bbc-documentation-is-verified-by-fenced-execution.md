# ADR: Documentation is verified by fenced execution, not by review

- **ID**: ADR-71c9304bbc
- **Status**: ADOPTED 2026-09-10 as [`docs/decisions/0018-documentation-is-verified-by-fenced-execution.md`](../../docs/decisions/0018-documentation-is-verified-by-fenced-execution.md)
  — owner-directed. The adopted record is authoritative; this draft is kept as the
  as-written artifact. The ID `ADR-71c9304bbc` is preserved in both and must not be
  recomputed.
- **Date**: 2026-09-10
- **Source retrospective**: ../2026-09-10-267.md
- **PRs covered**: #265, #266, #267

## Context

On 2026-09-10 the bring-up page had been through three authoring passes, two of
them careful enough to mark eight separate commands as unverified and to refuse
to flip the page's status marker. All three passes missed that the page's most
emphatic instruction described a dependency that does not exist: a warning
admonition, reinforced by a Mermaid diagram edge reading "waiting here before
gate 2 deadlocks", told the reader that waiting for the composite resource to
become Ready before the second gate would deadlock a fresh build.

One execution of the page by an agent that could read only that page disproved it
in a single run. The identity-provider association reached `Ready=True` at
01:13:50Z and the composite at 01:14:17Z, while the second gate was not synced
until 01:20:40Z — the association completed before the gate ran and before
Keycloak existed at all. The same run produced eight further findings, including
a safety check the page prescribed that cannot fail (`kp-2al.24`) and an EC2
capacity figure understated by one instance against a nine-instance account cap
(`kp-2al.25`).

The reason review missed all of it is structural, not a matter of care. A reviewer
who can read the repository resolves every ambiguity silently from the source, so
the page's omissions never become visible. The project already had a vocabulary
for this gap — the `contract` status marker, meaning "written from committed
sources, never executed" — but no mechanism to discharge it other than waiting for
a human. That made the marker a permanent state rather than a stage.

## Decision

A procedural document is considered verified only when an agent or person
executing it with access to that document and nothing else completes the
procedure, and every gap, guess or mismatch they report is filed as a defect.

Concretely: a page carrying the `contract` marker is discharged by a fenced
execution against a real environment, not by another review pass. The executing
reader is given the page, the credentials, and an explicit list of environment
substitutions; everything else is withheld by instruction. Correct guesses are
reported as findings alongside failures, because a guess that happened to be right
is a gap that will catch the next reader. A fenced execution does not replace the
human run where one is required by policy — in this repository the human run
remains its own task — but it is the gate a page must pass before a human is asked
to spend their time on it.

## Alternatives considered

**Another review pass, by a different author.** Rejected on the evidence: three
passes had already run, the last two of which were scrupulous about marking
unverified commands, and the false warning survived all three. Review cannot find
an omission whose absence the reviewer unconsciously fills.

**Wait for the human run and let the human find the defects.** This was the status
quo and it is expensive in the scarcest currency the project has. The human run is
the one thing that cannot be parallelised or retried cheaply, and it happens on a
rotating account with a limited lifetime. Spending it on findings a fenced agent
can produce in one run — nine of them, three serious — wastes the run. Worse, a
human who hits a false warning early learns to distrust the page, which
contaminates every later observation; the fenced agent said exactly this about
itself.

**Simulate the procedure: have an agent read the page and narrate what it would
do.** Rejected because every finding in the 2026-09-10 run came from a measured
divergence between the page's claim and a live system's behaviour. A narration has
no system to diverge from, so it can only restate the page's own assumptions more
confidently.

**Automate the procedure as a script and treat passing CI as verification.** This
is valuable and partially exists, but it verifies the mechanism, not the document.
The project's builds had passed six times against mechanisms the page described
incorrectly. A script cannot report that an instruction was ambiguous, because a
script does not read instructions.

## Consequences

**Easier.** A page's status marker becomes discharge-able on demand rather than
blocked on a person. Findings arrive with the page's wording quoted and a live
contradiction beside it, which makes them cheap to triage and to fix in the same
pass. The execution also produces real verification values, so it doubles as
evidence for whatever the procedure builds — the 2026-09-10 run supplied the
storage-ordering measurement that closed a separate bead.

**Harder.** Fenced execution is not free: it consumes a real environment, takes as
long as the procedure takes, and leaves state behind. It requires discipline in
the prompt, because a fence the agent can rationalise its way out of silently
degrades into an ordinary agent run. And the report must be triaged rather than
trusted: on 2026-09-10 one reported platform failure was in fact a defect in the
checking tool, and accepting the report at face value would have filed a false
security defect while missing a real test defect.

**Accepted trade-off.** We accept spending a real environment, and the triage
burden, in exchange for finding documentation defects before a human spends a
one-shot account on them. We also accept that a fenced execution does not license
flipping a page to `stable` where policy reserves that for a human run; the
fenced run discharges the page's readiness for that run, not the run itself.

## References

- [`../2026-09-10-267.md`](../2026-09-10-267.md) — the source retrospective.
- [`./SKILL-SPEC-bb3241e546-fenced-doc-dry-run.md`](./SKILL-SPEC-bb3241e546-fenced-doc-dry-run.md)
  — the method, with the fence construction and the triage step.
- `docs/decisions/0017` — the page status markers (`contract` versus `stable`)
  this decision gives a discharge path for.
- `docs/site/how-to/build-the-platform-from-nothing.md` — the page under test.
- Beads `kp-2al.23`, `kp-2al.24`, `kp-2al.25`, `kp-2al.26` — the findings.
- PRs the decision was made in: #265, #266, #267.
