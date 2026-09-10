# 0018 — Documentation is verified by fenced execution, not by review

- **ID**: ADR-71c9304bbc
- **Status**: Accepted (owner-directed adoption 2026-09-10)
- **Date**: 2026-09-10 (drafted in the build-#7 retrospective; adopted by owner direction the same day)
- **Source retrospective**: [`../../retrospective/2026-09-10-267.md`](../../retrospective/2026-09-10-267.md)
- **PRs covered**: #265, #266, #267 (the decision was made in these); adopted here
- **Mechanical enforcement**: none today, stated plainly rather than invented.
  This is a gate on *how* a page earns its stability marker, and the marker
  machinery it feeds already exists (`docs/hooks/status_banner.py` +
  `mkdocs build --strict`, per ADR-0015 and ADR-0017). A candidate check — require
  a page claiming fenced discharge to cite the execution that discharged it — is
  recorded in the source retrospective's Part 3 and deliberately not implemented
  here; `ai/LESSONS.md` §3 warns against prose rules whose violation the session's
  own goal rewards, and this one is not in that class: skipping a fenced run costs
  the owner's account window, which is the opposite of a reward.

## Context

On 2026-09-10 the bring-up page had been through three authoring passes, two of
them careful enough to mark eight separate commands as unverified and to refuse to
flip the page's stability marker. All three passes missed that the page's most
emphatic instruction described a dependency that does not exist: a warning
admonition, reinforced by a Mermaid diagram edge reading "waiting here before gate
2 deadlocks", told the reader that waiting for the composite resource to become
Ready before the second gate would deadlock a fresh build.

One execution of the page by an agent that could read only that page disproved it
in a single run. The identity-provider association reached `Ready=True` at
01:13:50Z and the composite at 01:14:17Z, while the second gate was not synced
until 01:20:40Z — the association completed before the gate ran and before Keycloak
existed at all. The same run produced eight further findings, including a safety
check the page prescribed that cannot fail (`kp-2al.24`) and an EC2 capacity figure
understated by one instance against a nine-instance account cap (`kp-2al.25`).

The reason review missed all of it is structural, not a matter of care. A reviewer
who can read the repository resolves every ambiguity silently from the source, so
the page's omissions never become visible. ADR-0017 established that bring-up is a
product surface and gave the page a `contract` marker meaning "written from
committed sources, never executed", with the obligation to run the human path and
flip it. What ADR-0017 did not provide was any way to discharge that obligation
short of spending the human run itself — which made `contract` a parking state
rather than a stage, and put the first real reader of the page in the position of
being its first tester.

## Decision

A procedural document is considered verified only when an agent or person
executing it with access to that document and nothing else completes the
procedure, and every gap, guess or mismatch they report is filed as a defect.

Concretely:

- A page at `contract` is **discharged for human execution** by a fenced execution
  against a real environment — not by another review pass.
- The executing reader is given the page, the credentials, and an explicit list of
  environment substitutions. Everything else is withheld by instruction: the
  agents file, other pages, the task graph, tests, source, and grepping the repo
  for answers.
- **Correct guesses are reported as findings** alongside failures, because a guess
  that happened to be right is a gap that will catch the next reader.
- The report is **triaged, not trusted**: a reported failure may be a defect in
  the checking tool rather than in the system.
- This does **not** flip a page to `stable`. ADR-0017 reserves that for a
  human-executed run and this decision leaves that reservation intact. A fenced
  execution discharges the page's *readiness* for that run; the run remains its own
  tracked obligation (`kp-2al.10`).

## Alternatives considered

**Another review pass, by a different author.** Rejected on the evidence: three
passes had already run, the last two of which were scrupulous about marking
unverified commands, and the false warning survived all three. Review cannot find
an omission whose absence the reviewer unconsciously fills.

**Wait for the human run and let the human find the defects.** This was the status
quo under ADR-0017 and it is expensive in the scarcest currency the project has.
The human run cannot be parallelised or retried cheaply, and it happens on a
rotating account with a limited lifetime. Spending it on findings a fenced agent
produces in one run — nine of them, three serious — wastes the run. Worse, a human
who hits a false warning early learns to distrust the page, which contaminates
every later observation; the fenced agent said exactly this about itself.

**Simulate the procedure: have an agent read the page and narrate what it would
do.** Rejected because every finding in the 2026-09-10 run came from a measured
divergence between the page's claim and a live system's behaviour. A narration has
no system to diverge from, so it can only restate the page's own assumptions more
confidently.

**Automate the procedure as a script and treat passing CI as verification.** This
is valuable and partially exists, but it verifies the mechanism, not the document.
The project's builds had passed six times against mechanisms the page described
incorrectly. A script cannot report that an instruction was ambiguous, because a
script does not read instructions. This is the same distinction ADR-0006 draws
between a behavioural oracle and a static check, applied to prose.

## Consequences

- **Easier:** a page's stability marker becomes discharge-able on demand rather
  than blocked on a person. Findings arrive with the page's wording quoted and a
  live contradiction beside it, which makes them cheap to triage and to fix in the
  same pass.
- **Easier:** the execution doubles as evidence for whatever the procedure builds.
  The 2026-09-10 run supplied the storage-ordering measurement that closed
  `kp-2al.19`, which build #6 had been unable to establish.
- **Harder / accepted:** fenced execution is not free. It consumes a real
  environment, takes as long as the procedure takes, and leaves state behind. On a
  rotating sandbox account that is a real budget line.
- **Harder / accepted:** the fence needs discipline in the prompt. A fence the
  agent can rationalise its way out of silently degrades into an ordinary agent
  run that finds nothing, and looks identical in the report.
- **Harder / accepted:** the report must be triaged rather than trusted. On
  2026-09-10 one reported platform failure was in fact a defect in the checking
  tool (`kp-2al.27`); accepting the report at face value would have filed a false
  security defect while missing a real test defect.
- **General principle recorded:** a reader who can consult the source silently
  fills the gaps a document leaves, so the only way to see an omission is to
  withhold everything except the document.

## References

- [`../../retrospective/2026-09-10-267.md`](../../retrospective/2026-09-10-267.md) — the source retrospective (Phases 7–8).
- [`../../retrospective/2026-09-10-267/SKILL-SPEC-bb3241e546-fenced-doc-dry-run.md`](../../retrospective/2026-09-10-267/SKILL-SPEC-bb3241e546-fenced-doc-dry-run.md) — the method: fence construction, the substitutions list, and the triage step. Not installed as a skill at adoption time.
- [`0017-bring-up-is-a-user-facing-product-surface.md`](0017-bring-up-is-a-user-facing-product-surface.md) — establishes bring-up as a product surface and the `contract` obligation this decision gives a discharge path for.
- [`0015-docs-site-diataxis-with-stability-markers.md`](0015-docs-site-diataxis-with-stability-markers.md) — the stability markers themselves.
- [`0006-test-architecture-build-coupled-behavioral-verification.md`](0006-test-architecture-build-coupled-behavioral-verification.md) — the behavioural-oracle-over-static-check principle this applies to prose.
- `docs/site/how-to/build-the-platform-from-nothing.md` — the page under test.
- Beads `kp-2al.23`, `kp-2al.24`, `kp-2al.25`, `kp-2al.26` (the findings), `kp-2al.27` (the mis-triaged one), `kp-2al.10` (the human run this does not replace).
- PRs #265, #266, #267.
