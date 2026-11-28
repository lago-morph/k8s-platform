# ADR: CI Live verify is a full verdict: every check runs, unregistered skips fail

- **ID**: ADR-4d858140f6
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-11-28
- **Source retrospective**: ../2026-11-28-296.md
- **PRs covered**: #278, #290, #293

## Context

On the owner's own bring-up (clean build #10, 2026-11-27), CI Live verify
reported PASS with `pass=17 skip=12`. The 12 skipped checks — secret sync,
spoke registration, hub Argo CD health, storage, login federation, IAM/ASM
instantiate, three guards — had never run in CI: the scoped verifier role has
no `ssm:StartSession` and no cluster access (ADR-0008), the producer ran
read-only, and the gate went red only for unverified AWS kinds or an
all-skipped run. Their coverage depended on manual agent "oracle runs", last
performed on build #7; builds #8–#10 verified none of them. Four checks also
mislabelled the permission denial as a "tunnel flake". The owner's ruling: a
verification pipeline that cannot run 40% of its checks is a defect, fixed
before step 3 closed.

## Decision

The CI Live verify producer runs the full suite in mutating mode with strict
skips, running checks that declare the cluster identity under the CI job
credentials and everything else under the scoped verifier role.

Concretely (`tests/live/run.sh`, `.github/scripts/live-verify-run.sh`):
`LIVE_STRICT_SKIPS=1` (a skip without a valid `SKIP_REGISTER.yaml` entry is a
FAIL); `# live-identity: cluster` header + `LIVE_CLUSTER_AWS_PROFILE`;
`LIVE_SHARED_TUNNELS` (one relay tunnel per cluster, never torn down by a
check); `LIVE_PARALLEL=8`. The reaper and account mutex stay on the scoped role.

## Alternatives considered

- **Widen the scoped verifier role** (relay StartSession, Cognito admin, hub and
  spoke access entries). Keeps least privilege, but the spoke entry is
  Crossplane-composed and reaches the live platform only through `main` (kp-ifh),
  so it could not be proven before merge. Deferred to step 6 (kp-zab.7) by the
  owner.
- **Keep the oracle runs manual.** That is what lapsed silently for three builds.
  Rejected.
- **Accept skips with better labels only.** Keeps a green verdict that does not
  verify the platform. Rejected.

## Consequences

- The verdict is honest: build #11 read `pass=30 skip=0 fail=0`, in 1m36s
  instead of ~15 min for 17 checks.
- Timing-sensitive checks now surface as real failures — the federation check
  failed right after BRING-UP COMPLETE (EKS OIDC propagation lag) and needed a
  bounded wait (#293). Any new check must be deterministic within the
  documented windows.
- CI runs cluster-access checks with admin credentials until kp-zab.7 lands a
  scoped grant; fixtures are tagged and self-cleaning, and every cleanup prints
  what it deleted and proves absence.

## References

- [`../2026-11-28-296.md`](../2026-11-28-296.md) — Phases 2 and 8.
- `tests/unit/test_live_orchestrator.sh`, `test_live_relay_hygiene.sh`,
  `test_live_suite_wired.sh`, `test_fed_auth_wait.sh`.
- PRs #278 (738e12a), #290, #293; beads kp-2al.37, kp-zab.6, kp-2al.57, kp-zab.7.
