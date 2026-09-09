# tests/live/checks/after

> Runs in: **full** (and verify-only)


Behavioral live checks for the **after** tier (FINAL-PLAN §4.2 tier→profile map).
Each `*.sh` here is a child check honoring the exit-code contract
(`tests/live/lib/live-lib.sh`): exit 0=pass, 2=allowed skip, 3=expect-full
violation, other=fail. A passing check declares the kind(s) it verifies with
`covers <group>/<Kind>` so the orchestrator can promote an unverified
git-declared kind to a FAIL.

Some checks prove a property that no managed resource maps to (a PVC that binds,
an endpoint whose TLS chain validates). Those emit an additive **synthetic**
marker instead — `platform.storage/bound-pvc`, `platform.hello/e2e`,
`platform.argocd/verified-tls` — which is deliberately NOT a coverage-registry
key (the registry's keys must all be derived MR kinds) and never appears in
`LIVE_EXPECT_FULL`.
