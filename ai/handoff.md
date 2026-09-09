# Session Handoff — k8s-platform

Verified state only (run IDs, SHAs, PR numbers, account shape). Open work
and next actions live in beads: `bd ready`. The plan and the definition
of "feature complete" live in `ai/roadmap.md`. Keep this file short:
replace stale facts, never append narrative. The pre-2026-09-08 handoff
is archived verbatim at `docs/archive/handoff-2026-09-08.md`.

## Verified 2026-09-08

| Fact | Value | Evidence |
|---|---|---|
| `main` | `df4c900` (PR #262 merged) | `git log` |
| Clean builds proven | five (#1–#5), rows 1–9 evidenced 2×–4× | `SUBSTRATE-READINESS.md` |
| Rows 10/11 | built, `pending clean-build verification` (build #6) | `SUBSTRATE-READINESS.md` |
| AWS account | fresh Pluralsight sandbox, empty except the hosted zone; owner activates and can extend | `scripts/whereami.sh`, creds probe |
| GHA secrets | valid for that account | `terraform-test.yml` test/test-e2e run 34273668606 (creds PASS, zone PASS, backend FAIL = expected before bootstrap) |
| CI dispatch from the sandbox | native GitHub MCP `actions_run_trigger` + `get_job_logs` work | same run |
| Jentic bridge | still works; hosted execution ends 2026-09-20; only needed for `.github/workflows/**` writes | `mcp__Jentic__list_credentials` deprecation notice |
| Sandbox git push | branch create + force-with-lease OK; non-branch refs and branch deletes HTTP 403 | probes 2026-09-08 (`ai/environment.md` §2) |
| Leftover | branch `probe-delete-me-ref-test` on origin awaits owner deletion | — |

## Environment state

The account rotates between sessions. Assume every phase `not applied`
until `scripts/whereami.sh` and the live API prove otherwise. When a
build is in progress, record the chain here as facts (probe → base →
management → gate SHAs → oracle RUN_ID → live-verify run ID) and move
them into `SUBSTRATE-READINESS.md` when the build completes.

| Phase | State | Run ID / SHA |
|---|---|---|
| state backend | not bootstrapped | — |
| base | not applied | — |
| management | not applied | — |
| gate 1 (platform-cluster-claim) | not pulled | — |
| gate 2 (spoke-access) | not pulled | — |
| oracles | not run | — |
| live-verify | not run | — |
