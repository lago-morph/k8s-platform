# Clean build #6 — the recipe for a non-improvising executor

Assembled 2026-09-08 from the repository's own scripts, skills, checks and
build records (every step cites its source). Executes on a fresh account
from the Claude Code web sandbox. Where the repository does NOT specify a
mechanic, the step says **GAP** and what to do instead of guessing.
Owner intent: this build is the step 3 "see it all working" milestone
(`ai/roadmap.md`). Evidence goes into `SUBSTRATE-READINESS.md` rows 10/11.

## 0. Scope

- Build #6 earns rows 10 and 11 (`SUBSTRATE-READINESS.md`), the only rows
  still `pending clean-build verification`. Rows 1–9 are already 2×–4×
  evidenced; do not re-litigate them.
- A fresh account is mandatory: a live Keycloak realm never re-imports
  (`IGNORE_EXISTING`), so the Cognito broker only becomes real on a fresh
  Keycloak DB (row 10; `tests/live/checks/instantiate/cognito-federation-live.sh` header).
- Build #5 already verified the EKS-side association ACTIVE; build #6 must
  produce the realm-broker half plus the federation oracle from scratch.

## 1. Preconditions

1. **Orientation** (`AGENTS.md`): `scripts/whereami.sh` first. Exit 1 = no
   AWS creds. Treat the account as empty until the live API says otherwise.
2. **Account shape**: only the Route53 hosted zone should exist; no state
   bucket, EKS, IRSA, ACM, Cognito (`ai/environment.md` §1). Constraints:
   us-east-1/us-west-2, small instances, EC2 quota (9 instances → one
   shared kube relay, `scripts/sandbox-kubeconfig.sh` header).
3. **GHA secrets valid**: dispatch `terraform-test.yml` with
   `phase=test action=test-e2e` (native GitHub MCP `actions_run_trigger`,
   `ref=main`). Expected shape on a fresh account: creds PASS, zone PASS,
   state backend FAIL (bucket/table absent before bootstrap) → the run is
   red and that red IS the pass signal for this probe only. Precedent:
   run 34273668606 (2026-09-08), 28757370347 (build #5).
4. **Sandbox tools**: the SessionStart hook installs yq, kubeconform,
   crossplane, aws, helm, argocd, kubectl, session-manager-plugin from
   `versions.env`. Required for the relay and oracles: `aws`, `kubectl`,
   `jq`, `session-manager-plugin`. A missing binary makes an oracle SKIP,
   which `expect-full` turns into FAIL — verify tools BEFORE the evidence
   pass. Before declaring a tool unavailable, probe PATH and try the
   one-line install (`ai/environment.md` §5).
5. **CI mechanics**: never foreground-poll a run — one background waiter;
   never raw-curl `api.github.com` (403 after ~6 polls). Read logs with
   `get_job_logs` (`run_id`, `failed_only`, `return_content`).
6. **Ref check**: confirm the ref you build from carries the corrected gate
   ordering (`docs/site/how-to/build-the-platform-from-nothing.md` §3 waits
   on the four status facts, merged in PR #262).

## 2. Recipe

### (a) terraform base via CI

Dispatch `terraform-test.yml` `phase=base action=apply-and-verify` on
`main`. The run bootstraps the state backend (bucket/lock table derived
from the account id) and discovers the first public hosted zone (hard fail
if none). Green = conclusion `success` with `[base] e2e-verify` green.
Expect ~3–4 min. Reference runs: #5 28757434684, #4 28746752536.

### (b) terraform management via CI

Dispatch `phase=management action=apply-and-verify`. Installs the hub
EKS `k8-platform-mgmt`, Argo CD, Crossplane, ESO, the bootstrap
Application, and the shared SSM kube relay. `[management] argocd-url` is
`continue-on-error`, so it never fails the run. Expect ~15–17 min.
Concurrency is one run per branch+phase and follow-ups queue — **never
cancel a mid-apply run** (held state lock, half-applied resources).
Reference runs: #5 28757800712, #4 28750304494.

### (c) hub access from the sandbox

```sh
scripts/sandbox-kubeconfig.sh -c k8-platform-mgmt --exec kubectl get applications -n argocd
# or interactive:
eval "$(scripts/sandbox-kubeconfig.sh -c k8-platform-mgmt)"; kubectl get nodes
scripts/sandbox-kubeconfig.sh --stop
```

Direct kubectl 503s at the egress gateway (cluster-private CA); the SSM
tunnel is the committed path (ADR-0008). Failure modes
(`.claude/skills/sandbox-kubectl-access/SKILL.md`): "No relay instance
found" = management apply not complete; hang on "Waiting for connections"
= SSM agent down; `Unauthorized` = the Composition's `kube-relay-ingress`
/ `sandbox-access-entry` not rendered; 503 despite tunnel = KUBECONFIG
still points at the direct endpoint. `--stop` kills the process group.
`cloud_user` is read-only (`AmazonEKSAdminViewPolicy`) on spokes and hub
admin; the skill's cluster-admin self-grant exists for mutating test
tiers only — **never use it to clear a build blocker**.

Argo CD credentials come from terraform outputs
(`argocd_server_url`, `argocd_admin_password`), never from the
initial-admin Secret. The sync form below needs only kubectl; the
`argocd` CLI installs in some sessions and not others
(`ai/environment.md` §3), so the kubectl form is the recipe.

### (d) gate 1 — `platform-cluster-claim`

1. Verify the LIVE Application spec matches merged source (bootstrap must
   have synced any `argocd/apps/*` edit first — L37):
   `kubectl -n argocd get application platform-cluster-claim -o jsonpath='{.spec.source}'`
2. Sync by explicit SHA, never by branch name (repo-server cache — L37):
   ```sh
   kubectl -n argocd patch application platform-cluster-claim --type merge \
     -p '{"operation":{"sync":{"revision":"<EXPLICIT-SHA>"}}}'
   ```
   **GAP:** the committed instances of this patch use `"main"`/`"HEAD"`;
   putting the SHA in `revision` is the documented Argo CD operation
   field, applied by inference from the "sync by SHA" rule. Verify after
   the sync that `.status.sync.revision` equals the SHA; if it does not,
   stop and record.
3. Wait on the published facts, NOT XR Ready (XR Ready before gate 2
   deadlocks a fresh build — the IdP association needs Keycloak, which
   needs gate 2):
   ```sh
   for fact in oidcIssuer endpoint clusterCaData certificateArn; do
     kubectl wait --for=jsonpath="{.status.${fact}}" --timeout=1500s xplatformclusters -A --all
   done
   kubectl wait --for=condition=Ready --timeout=1500s nodegroups.eks.aws.m.upbound.io -A --all
   ```
   Expect 15–20 min. Diagnose with `scripts/crossplane-trace.sh <kind>/<name> [-n ns] --watch`
   (read-only; exit 0 on Ready, 2 on timeout) or the `crossplane-claim-verify` skill.

### (e) gate 2 — `spoke-access`

Sync the same way (explicit SHA). Then wait for the XR Ready LAST:
`kubectl wait --for=condition=Ready --timeout=2400s xplatformclusters -A --all`.
On a fresh build the association fail-retries until Keycloak's issuer
serves — a known property, not a defect.

"Registration Secret complete" (ADR-0010, asserted by
`tests/live/checks/after/spoke-cluster-secret-live.sh`): on the hub, ns
`argocd`, ≥1 Secret with labels
`argocd.argoproj.io/secret-type=cluster,k8-platform.io/cluster-role=spoke`,
all five annotations `k8-platform.io/{domain,subdomain,certificate-arn,external-dns-role-arn,region}`
non-empty, label `k8-platform.io/short-name`, and `data.{name,server,config}`
with `config` decoding to `.awsAuthConfig.clusterName` + `.tlsClientConfig.caData`.
The producer is complete-or-absent: a partial Secret is a defect, never a
wait state. It appeared ~3 min after the sync on prior builds.

### (f) app-stack convergence

Oracle page: `docs/site/reference/finished-platform.md`. Hub apps that
must be Synced/Healthy: bootstrap, crossplane-resources,
management-cluster-config, keycloak-db, keycloak-secrets, and after their
syncs platform-cluster-claim, spoke-access. Per-spoke: platform-ingress-nginx,
platform-external-dns, platform-eso, platform-hello, platform-keycloak.
Expected non-green, do not "fix": `workload1-cluster` (OutOfSync by
design) and the observability set (Degraded/Progressing = OI-2026-06-11-3,
a step 3 defect fixed in code, not by hand). XRs all Synced/Ready/Responsive:
the platform-cluster XR, the spoke-access XR, `keycloak-db`,
`keycloak-admin`, `keycloak-oidc-clients`. Endpoints: hello → 200 with
valid TLS; argocd valid cert; grafana not until the storage fix.
Snapshot helper: `scripts/argocd-apps.sh` (read-only).

### (g) oracles

Entry point `tests/live/run.sh [LIVE_MODE]`; env `LIVE_PROFILE`
(`full` = after+instantiate+negative; `verify-only` = after only),
`LIVE_MODE` (`readonly` default, fail-closed; `mutating` enables the
instantiate mutations), `LIVE_CLUSTER` (cluster under test; the
registration Secret is always read from the hub, `LIVE_HUB_CLUSTER`
default `k8-platform-mgmt`), `RUN_ID`. Exit codes: 0 clean; 1 a check
failed or all-skipped; 3 an expect-full kind not verified. All-skipped is
RED by design.

`RUN_ID` convention from the build records: `build6-<HHMM>` (build #5 used
`build5-2347`). It names every mutating fixture and the reaper's tag
condition, so choose it once and reuse it. **GAP:** no lint enforces the
format.

| Oracle | Tier / mode | PASS means |
|---|---|---|
| `hello-e2e-live` | after / read-only | HTTP 200 + body marker over valid TLS within 300 s; hub `spoke-hello` Synced+Healthy |
| `spoke-cluster-secret-live` | after / read-only | the full ADR-0010 contract above |
| `sandbox-kubectl-relay` | after / read-only | real tunnel + `kubectl get nodes` on `LIVE_CLUSTER` (spoke: 2 Ready) |
| `rds-instance-live` | after / read-only | XDatabase-tagged instance `available`, in the base VPC |
| `keycloak-e2e-live` | after / read-only | OIDC discovery 200 with matching issuer within 600 s; hub `spoke-keycloak` Synced+Healthy |
| `secretsmanager-secret-live` | after / read-only | crossplane-tagged ASM secret with AWSCURRENT; never reads the value |
| `eks-identity-provider-config-live` | after / read-only | IdP config `keycloak` ACTIVE with the claim contract (CREATING = loud skip; FAILED = hard FAIL) |
| `cognito-federation-live` | instantiate / **mutating only** | hosted-UI login → broker → PKCE code → ID token (`preferred_username`, `groups ∋ k8s-viewers`) → SelfSubjectReview on the spoke reports `kc:<email>` + `kc:k8s-viewers`; self-reaped fixture user |

The CI producer runs `readonly`, so the federation oracle's evidence can
ONLY come from a sandbox mutating run. In `full`+`mutating`, `run.sh`
runs the reaper first, then takes the account-mutex lease and renews it
before every check; losing the lease is an immediate RED — never re-run
over another holder. `LIVE_REAPER_DRY_RUN=1` forces observe-only.

Invocation (the tested path is the orchestrator; **GAP:** build #5's
per-check command lines were not committed, do not invent a wrapper):
```sh
RUN_ID=build6-HHMM LIVE_CLUSTER=<spoke-cluster-name> LIVE_PROFILE=full bash tests/live/run.sh mutating
```

### (h) live-verify dispatch

`live-verify.yml`, input `profile=full`. The producer assumes the scoped
`k8-platform-mgmt-live-verifier-reaper` role (session tag `live-verify`)
and runs `tests/live/run.sh readonly` with an explicit 13-kind
expect-full list (RDS Instance; secretsmanager Secret; IAM OIDC provider,
RolePolicy, Role, RolePolicyAttachment; ACM Certificate,
CertificateValidation; EKS Cluster, NodeGroup, AccessEntry,
AccessPolicyAssociation; Route53 Record). Evidence JSON is emitted only on
a clean pass. Required result: conclusion `success`, zero expect-full
violations, pass count in build #5's class (13). If the verifier-role
policy changes: merge → management apply → dispatch → green.

### (i) recording rows 10 and 11

Rules (`SUBSTRATE-READINESS.md`): a row flips only with a verifiable
pointer; evidence = a `terraform-test.yml apply-and-verify` run ID AND a
GitOps sync from committed `main` with no out-of-band patches AND the
behavioral check passing on that build; a hand-fix is never evidence; no
oracle run IDs = no row (build #4 died before its oracles and got no rows).

Write, modeled on the build #5 block: a header (date, account id with the
`<!-- noqa: account-id - run provenance, account rotates -->` comment, the
`main` SHA, probe → base → management → gate-1 SHA → gate-2 → convergence,
"Zero manual steps."), the oracle line with `RUN_ID`, the live-verify
line, then row 10 (broker real on the fresh DB + `cognito-federation-live`
PASS) and row 11 (IdP config composed from scratch +
`eks-identity-provider-config-live` PASS + the oracle's kubectl leg), and
item 5 of "The order of operations". Sequencing (§7.1 of
`ai/testing-guidelines.md`): content commits pushed → dispatch at that
exact HEAD → run IDs committed afterwards as a docs-only commit. Never
type a run ID; paste it (L39).

## 3. Known traps

1. Branch-name sync hits the repo-server's ~3-min cache → sync by SHA (L37).
2. `argocd/apps/*` edits reach the live spec only after bootstrap syncs → verify the live spec before pulling a gate (L37).
3. Never push to a gated branch while its dispatch is in flight; `chainsaw.yml` cancels in-progress per ref and skips its cleanup trap; `head_sha` resolves at run creation (L33). `terraform-test.yml` queues instead.
4. Kubeconfig truncate race (L34) fixed in #245; prior greens were timing luck.
5. ExternalSecret CRD-default enums must be pinned or ArgoCD loops OutOfSync forever (L40).
6. Exact-HEAD gates: content → dispatch → docs-only run-ID commit; never fabricate a run ID (L39).
7. XR-Ready-before-spoke-access deadlock — see (d).
8. Bootstrap-time Applications must not target namespaces created by manual gates (L35).
9. AWS tag charset (L36): `scripts/pre-chainsaw-audit.sh` catches it statically.
10. upjet ASM observe needs `secretsmanager:GetResourcePolicy` or the MR wedges Synced=False.
11. A denied read under the scoped verifier role is never world state (L38).
12. Runner image drift: `ubuntu-24.04` ships `session-manager-plugin`, changing skip-guard meaning.
13. Sandbox git: branch create and force-with-lease OK; non-branch refs and branch deletes 403; workflow files only via jentic.
14. When a gate fails identically across content changes, re-run the last-green SHA first (L32).
15. After any merge touching the Cognito→ASM chain, dispatch a base apply (Keycloak's `KC_COGNITO_*` env is fail-closed on that document).

## 4. Stop conditions — record a beads bug, do not improvise

1. Any urge to hand-mutate AWS or Kubernetes state (IAM, SG, tags, `kubectl apply`, overlays, REST registrations, namespace creation, bootstrap pauses). Reads are unrestricted.
2. A red gate: fix code or check; never re-kick, merge around, or de-gate (ADR-0009).
3. A new live defect: red-first test at the closest layer, fix in code, merge, let GitOps propagate; if it cannot land this session it is a bug, not a hand-fix.
4. Any undiagnosed failure at session end.
5. A wait past its budget (cluster >20 min, XR Ready >21 min + stack rollout, discovery >600 s): trace, do not sync more or delete.
6. Account death before the oracles: no rows.
7. Account-mutex lease unavailable or lost.
8. Any of the three GAPs above (explicit-SHA payload, per-check invocation, RUN_ID format): ask, do not invent.
9. Never commit to `main`; never commit tfvars, state, or secrets.

## 5. Not verifiable from the repository

- Whether the current account still exists at execution time (re-probe).
- Whether jentic still works on the day (announced end 2026-09-20); native MCP covers dispatch and logs.
- Build #5's exact per-check sandbox command lines (recorded as results only).
- Whether `argocd app sync` (the how-to's human form) works in the sandbox; the kubectl-patch form is the sandbox path.
