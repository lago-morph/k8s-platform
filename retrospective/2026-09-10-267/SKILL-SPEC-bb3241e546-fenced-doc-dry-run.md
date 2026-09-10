# Spec: `fenced-doc-dry-run`

- **ID**: SKILL-SPEC-bb3241e546
- **Source retrospective**: ../2026-09-10-267.md

## Intent

Verify a procedural document by having an agent execute it with access to that
document and nothing else. A reader who can consult the codebase silently fills
every gap the page leaves, so review cannot find omissions; a fenced reader
cannot, so every gap becomes an observable failure. On 2026-09-10 this technique
executed the platform bring-up page end to end on an empty AWS account and
produced nine findings, including that the page's most emphatic warning was
factually false.

The cost asymmetry is what earns it a place. Three separate authoring passes had
already reviewed `docs/site/how-to/build-the-platform-from-nothing.md`, and two
of those passes were careful enough to mark eight commands as unverified. None of
them found that the page's `!!! warning` admonition — reinforced by a Mermaid
diagram with an edge labelled "waiting here before gate 2 deadlocks" — described
a dependency that does not exist. One fenced execution found it in a single run,
because the page's claim and the cluster's behaviour were side by side.

## Trigger

**Direct triggers:**

- "Test the documentation", "dry run the runbook", "does the page actually work?"
- "Have an agent follow only the docs"
- Any request to validate a how-to, runbook, or onboarding page before a human
  relies on it.

**Proactive triggers — offer the technique:**

- A procedural page is about to be handed to a person for the first time.
- A page carries a `contract`-grade status marker (written from source, never
  executed) and the environment needed to execute it is currently available.
- A page has just been substantially rewritten, especially by several authors or
  passes.
- The cost of the page being wrong is high: a long provisioning run, a paid
  resource, a one-shot account.

**Negative triggers — do not use this:**

- The page is reference material rather than a procedure (an inventory, a
  glossary, an API listing). There is nothing to execute.
- The procedure cannot be run without destroying something the session needs.
- No environment is available, so the agent would have to simulate the steps.
  A simulated dry run finds nothing; it only launders the page's own assumptions.

## Inputs

- **The page under test** — exactly one path. If the procedure genuinely spans
  two pages, that is itself a finding; test the entry point and let the agent
  report the handoff.
- **Credentials and environment access** the procedure needs, supplied directly
  rather than by pointing at repo documentation.
- **A short list of environment substitutions** — the places where the executing
  agent's sandbox differs from the page's intended reader, each named explicitly
  so it is not mistaken for a documentation defect. On 2026-09-10 there were
  three: use the SSM relay where the page says `aws eks update-kubeconfig`, use
  the workflow-dispatch API where the page says to click a button, and expect a
  pre-existing state bucket because the account had been reset rather than
  freshly provisioned.
- **A rating scale** for findings, so the report is triageable on arrival.

## Outputs

- A **step-by-step table**: page step, outcome (worked as written / worked with a
  guess / failed), and a one-line note.
- A **findings list**, each with a rating, the exact page wording at fault, the
  exact error or mismatch observed, and a concrete suggested edit.
- The **verification results** the page itself asks for, with real measured
  values, which double as evidence for whatever the procedure builds.
- A statement of **how far the agent got** and what blocked it.
- The agent's answer to one subjective question: **the single most confusing
  thing about the page**. This is where the highest-value finding usually lands.

## Workflow

1. **Confirm the environment is real and in the state the page assumes.** Verify
   it yourself before dispatching; do not make the fenced agent discover that the
   starting state is wrong. On 2026-09-10 the account was checked empty (no
   clusters, no load balancers, no databases, no platform IAM roles) before the
   dry run started.
2. **Write the fence explicitly.** Name the one file the agent may read, and
   forbid the rest of the repository by name: the agents file, other pages, the
   task graph, tests, source. Forbid grepping the repo for answers. A fence the
   agent can rationalise its way out of produces a normal agent run.
3. **Supply the environment substitutions** as a short numbered list, each
   labelled "this is an environment difference, not a documentation defect".
   Without this the report fills with noise about the sandbox.
4. **Instruct it not to stop at the first failure.** Record the finding, work
   around it, continue, and stop only when everything remaining is blocked by a
   finding already recorded. A dry run that halts on step one tests one step.
5. **Demand that guesses be reported as findings, even correct guesses.** This is
   the instruction that produces the most useful output, because a guess that
   happened to be right is a gap that will catch the next reader.
6. **Require a running log with timestamps** at a known path, so durations and
   orderings are recoverable afterwards as evidence.
7. **Do not let the agent file the defects itself.** Filing requires knowing the
   task-graph conventions, which means reading the repo, which breaks the fence.
   Take its report and file from it.
8. **Triage the report against reality before filing.** Several findings will be
   environment artefacts or the agent's own misreading. On 2026-09-10 one
   reported failure (a security guard "not effective") turned out, on a direct
   120-second experiment, to be a defect in the checking tool rather than in the
   platform — and that re-investigation produced a better finding than the
   original report.
9. **File each surviving finding with the page wording quoted verbatim** and the
   measured contradiction beside it, then correct the page in the same pass while
   the evidence is fresh.

## Concrete examples

### Example 1 — the false deadlock warning

Fence: the agent could read only
`docs/site/how-to/build-the-platform-from-nothing.md`.

The page said, in a warning admonition: *"Do not wait for the composite resource
to become Ready here … Waiting for `Ready` before gate 2 deadlocks a fresh
build."*

The agent executed the build and measured:

```
identityproviderconfig/platform-5183a6d2c254  Ready=True reason=Available  01:13:50Z
xplatformcluster/platform                     Ready=True                   01:14:17Z
gate 2 (spoke-access) synced                                               01:20:40Z
```

The association completed six minutes before gate 2 and before Keycloak existed.
No deadlock, no retry loop. Filed as `kp-2al.23`; the claim was also propagated in
`ai/recipes/clean-build-6.md` and on a second page, so the fix touched three
files. The agent's closing comment is the part worth keeping: because the page
spent more design effort on that warning than on anything else, it calibrated its
trust on it, and its guesses clustered immediately afterwards.

### Example 2 — the safety check that could not fail

The page told the reader to confirm a gate synced at the intended commit by
reading `.status.sync.revision`, and to stop if the value did not match.

The agent observed that field already holding the correct commit for a gate that
was still `OutOfSync` and had never synced at all. The check therefore passes for
an unsynced gate and cannot detect the failure it exists to catch. Filed as
`kp-2al.24`, with the replacement being a read of the completed operation
(`.status.operationState.phase` plus `.status.operationState.syncResult.revision`).

This finding had a second consequence the dry run could not know about: the same
weak check had been cited as gate evidence in the project's readiness record, so
that wording had to be softened to what the weaker check actually established.

## Anti-patterns

- **Letting the agent read the repository "just for context".** The fence is the
  instrument. On 2026-09-10 the agent was explicitly allowed one exception (a
  relay script needed because the sandbox cannot reach API servers) and that
  exception was named in the prompt, not left to judgement.
- **Simulating the procedure instead of executing it.** Every finding in the
  2026-09-10 run came from a real divergence between the page and a live system.
  A walkthrough would have produced none of them.
- **Treating the report as ground truth.** One reported platform failure was
  actually a broken check; accepting the report would have filed a false security
  defect and missed a real test defect.
- **Reporting only failures.** The correct guesses are the findings that predict
  the next reader's mistakes.
- **Running it on a resource you cannot afford to rebuild.** Execution is real:
  it provisions, it costs, and it may leave state behind.
- **Asking the fenced agent to file tasks or commit.** Both require repo
  knowledge and both break the fence.

## Acceptance criteria

1. The executing agent reached a terminal state — completed the procedure, or
   stopped only at findings it had already recorded — and said which.
2. Every finding carries the page's wording verbatim, the observed contradiction,
   and a concrete suggested edit.
3. Guesses are reported as findings, with the correct ones included.
4. Environment substitutions named in the prompt appear nowhere in the findings.
5. The page is corrected in the same pass, and any claim the run disproved is
   corrected everywhere it was propagated, not only on the page under test.

## Files this skill creates / modifies

- A timestamped execution log at a path given in the prompt, for example
  `/tmp/claude-0/dryrun.log` — durations and orderings as evidence.
- Task-graph entries for each surviving finding, filed by the dispatching agent.
- The page under test, plus any other file repeating a disproved claim.
- Whatever the procedure itself builds; the verification values it reports
  become evidence for that build.
