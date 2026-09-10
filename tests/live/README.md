# tests/live — the LIVE behavioral suite

The inverted-skip behavioral suite (FINAL-PLAN §2, §4). Where
`tests/integration/run.sh` exits 0 whenever `FAIL==0` — so an all-skipped run on
a rotated/empty account reads GREEN, the disease this overhaul kills — this suite
treats **all-skipped ⇒ RED**, per profile, and promotes a SKIP of a git-declared
(`expect-full`) kind to a **FAIL**.

It **reuses** `tests/integration/lib/test-lib.sh` (no fork); the inversion lives
only in the orchestrator's tabulation and in `lib/live-lib.sh`'s exit-code
contract (a live `skip()` is exit 2, never the integration lib's silent exit 0).

## Exit-code contract (`lib/live-lib.sh`)

| child exit | meaning |
|---|---|
| `0` | pass — declare verified kinds with `covers <group>/<Kind>` |
| `2` | allowed skip (not-applicable, or git does not declare the kind for this cluster) |
| `3` | expect-full violation (git declares the kind but the real resource is absent) |
| other | FAIL |

Orchestrator exit: `0` clean; `1` a check failed OR **all-skipped/zero-checks**
under the active profile; `3` an expect-full kind was not verified by a pass.

The summary line's `expect-full-violations=N` counts **every** violation the
block beneath it names — the git-declared kinds no passing check covered plus the
children that exited `3` — and `N > 0` is exactly exit `3` (kp-lc5: the counter
once read `0` while four violations were printed).

## `LIVE_CLUSTER` vs `LIVE_HUB_CLUSTER`

`LIVE_CLUSTER` is the ONE cluster under test and is routinely a **spoke**. Checks
that assert **hub** fixtures (the `argocd` / `crossplane-system` namespaces and
the objects in them) address `live_hub_cluster()` instead — `LIVE_HUB_CLUSTER`,
default `k8-platform-mgmt` — or they skip structurally and can never pass
(kp-ug3). Such a check reports a missing hub fixture with `hub_fixture_absent`,
which prints `HUB-FIXTURE-ABSENT <what>`; the orchestrator promotes that skip to
a **FAIL**, because the hub answered and the absence is structural. A skip for
absent tooling/creds/relay prints no marker and stays a skip.

## EXPECT-FULL vs the derived coverage set

The gated set is `tests/coverage/derive-coverage.sh --expect-full`: the kinds the
Compositions declare, MINUS the kinds `tests/coverage/registry.yaml` marks
`coverage: transitive` (no standalone check; proven by a coupled check's
assertions, which is why they emit no `COVERS` line of their own — kp-2al.20).

## `LIVE_PROFILE` (which TIERS run) — default `full`

| profile | tiers | when |
|---|---|---|
| `full` (DEFAULT) | `after` + `instantiate` + `negative` | a component under active development |
| `verify-only` | `after` only (read-only) | a proven component on a routine bring-up |
| `off` | none | RED + non-zero unless an audited `disable_all` register entry exists |

`full` being the default is a **tested invariant** (`LIVE_PROFILE_DEFAULT=full` in
`run.sh` is the single committed source the unit test reads). A non-`full` choice
is recorded in `SKIP_REGISTER.yaml` — never a silent reduction.

## `LIVE_MODE` (read-only vs mutating WITHIN the running tiers) — fail-closed

Unset/garbage ⇒ `readonly` (an under-specified invocation degrades to safe, never
to provisioning). `verify-only` implies `readonly`; `verify-only` + `mutating` is
rejected. Only the `instantiate` create-path checks consult `mutating`; the
`after` existence/convergence floor is mode-independent.

## Tier dirs

`checks/after/`, `checks/instantiate/`, `checks/negative/` hold the child checks.
They are populated by the later phases (P2 after-the-fact, P4 instantiate, P5
negatives); until then a real run is correctly RED (verifies nothing ⇒ not green).

## Test seams (hermetic unit suite)

`tests/unit/test_live_orchestrator.sh` drives `run.sh` with stub checks via
`LIVE_CHECKS_ROOT`, `LIVE_EXPECT_FULL`, and `LIVE_SKIP_REGISTER` — no cluster, no
AWS — proving the tabulation, profile/mode logic, expect-full promotion, and the
off-register guard.
