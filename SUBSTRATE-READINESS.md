# SUBSTRATE-READINESS.md — the definition of "done" for the platform bring-up

This file exists because "done" kept meaning *"I made the live symptom go away with a
hand-fix"* instead of *"the committed code produces a working platform from nothing."*
Those are different, and conflating them is why the same gaps keep biting on every
fresh account.

This is a **gate, not a wish.** An item is DONE only when its **Clean-build evidence**
column holds a verifiable pointer. No pointer ⇒ the status is
`pending clean-build verification` — never "done", "fixed", "works", or "proven".

---

## Definition of done (the only one)

> A build from **committed `main`** — terraform phases 0→1 via CI `apply-and-verify`,
> then the spoke via **ArgoCD GitOps** synced from committed `main` — brings up
> **hub Ready + spoke Ready + `hello.platform.<domain>` → HTTP 200 (valid public cert)**,
> with **ZERO manual steps**.

The substrate is not done until that is true and captured with evidence below.

## What counts as a manual step (i.e. a FAILURE of the definition)

If a clean bring-up needs **any** of these, it is **not** done — the thing that
required the step is an open blocker, not a closed issue:

- An inline IAM policy / `aws iam put-role-policy` to make a controller work.
- `aws ec2 authorize-security-group-ingress` (hub→spoke or otherwise).
- `aws ec2 create-tags` on subnets.
- A hand `kubectl apply` / `kubectl create namespace` of anything ArgoCD/Crossplane
  should own.
- An `argocd app set` / `kubectl patch` overlay of a placeholder value.
- Pausing or `ignoreDifferences`-ing `bootstrap` to make an overlay stick.
- Hand-registering the spoke cluster Secret with ArgoCD.

## What counts as Clean-build evidence (the only thing that earns a checkmark)

- A **CI run ID** of `terraform-test.yml apply-and-verify` from the committed branch
  (the IAM/terraform layer), **AND**
- a **GitOps sync from committed `main`/the branch** (no out-of-band patches), **AND**
- the relevant **behavioral check passing on that build** (the live-suite check or a
  recorded `kubectl`/`curl` result).

A live hand-fix is **NOT** evidence. It validates the *mechanism*, never the *artifact*.

---

## The readiness checklist

**Clean build #9 — 2026-09-12, a NEW account (`851725259254`), nothing in <!-- noqa: account-id - run provenance, account rotates -->
it but the pre-existing hosted zone**
**(ninth from-scratch build; the OPS-BOX build — the first driven by the
committed ops box and its `k8p-bringup.sh` rather than by an operator
interpreting workflow logs. Single-SHA on the platform side: probe, both
applies and both gate syncs ran one `main` SHA,
`b41f48cdc0e7a532da4c69305d41133bf822e541`; the ops box and its scripts ran
the feature branch, heads `31c812a` → `9011d56` as the run found and fixed
two script defects.)**
Region us-east-1; hub EKS `k8-platform-mgmt`, spoke EKS
`k8-platform-services`.
Build chain: probe (`test` / `test-e2e`) **34672814841**, red by design
(creds 3/3, zone 4/4, state-backend **0/2** — the documented fresh-account
signature) → ops box **34673149665**, `apply`, success in **2m18s**, its
self-test printing the status screen with credentials and zone GREEN and
every stage RED → base **34673406430**, `apply-and-verify` success,
**3m14s** → management **34673599867**, success, **18m42s** → gate 1
`platform-cluster-claim` synced by the driver at `b41f48c…`, confirmed by
its completed operation, four facts and node group Ready **14m31s** from
the sync → gate 2 `spoke-access`, same SHA, XSpokeAccess Ready **4m00s**
→ 17 Applications converged (`workload1-cluster` OutOfSync by design)
**4m47s** later → hello endpoint HTTP 200 with the expected body → Live
verify **RUN_LIVE**, profile `full`, DUR_LIVE.
**Two script defects the live run exposed, both fixed with a red-first
unit test and re-verified on the box (`kp-2al.34`):** (1) `check_base`
went GREEN **46 s** into the base apply — the certificate was ISSUED and
the pool existed at 04:36:02 while the apply ran until 04:38:33 — so the
phase checks now also require the phase's Terraform state object to exist
and its DynamoDB lock item to be absent (probed live: base settled,
management held during its apply); (2) `check_endpoint` trusted the box's
VPC resolver, which had cached NXDOMAIN for `hello.platform` (Route53 SOA
minimum 900 s) because the driver asked before ExternalDNS wrote the
record — the endpoint answered 200 from the sandbox at the same moment —
so the check now reads the record from Route53 and pins the request with
`--resolve`; the re-run went `BRING-UP COMPLETE` in 2 s and
`k8p-status.sh` read ALL GREEN.
**Teardown:** see `ai/handoff.md` (executed at the end of the same session
so the account is fresh for `kp-2al.10`).

**Clean build #7 — 2026-09-10, the same account as build #6 (`801822495028`), <!-- noqa: account-id - run provenance, account rotates -->
emptied to nothing and rebuilt from scratch**
**(seventh consecutive from-scratch build; the DOCUMENTATION build — the
bring-up was executed by a FENCED AGENT allowed to read only
`docs/site/how-to/build-the-platform-from-nothing.md` and no other file in
this repository, so the build tested the page as much as the platform.
Single-SHA on the PLATFORM side — every apply and both gate syncs ran one
`main` SHA — but the verification harness ran a different, branch SHA; the
SHA note below says which did what.)**
Region us-east-1; hub EKS `k8-platform-mgmt`, spoke EKS
`k8-platform-services`.
**The teardown that preceded it:** management destroy **34419405234**
(13 min) → base destroy **34420560366**. An IAM fix landed mid-teardown
(commit `6e84258`, so that role DELETE could succeed) and was applied by
management run **34418948661** in **48 s**. The account was then verified
empty: no EKS clusters, zero load balancers, zero RDS instances, and no
`k8-platform-*` IAM roles besides the hub's.
**SHA note (two SHAs, doing different work):**
`3298e70f614d793f040ea4d6b97c4455cfe028b9` = `main`, the SHA the
**platform** was built from — probe, base, management and **both** gate
syncs ·
`bf520ba353d4544339175076ea66dacbf49d2bcc` = the branch head carrying the
**harness** fixes, and the ref live-verify ran. The two sandbox oracle
runs ran the same **branch** harness: `kp-ug3`'s hub-targeting fix was in
it (hence zero skips), while the destination-guard check's own defect
still was (hence that check's failure) — the fix for it is `bf520ba`
itself, so the oracle runs sit at or before that commit. **No single SHA
produced all of the evidence below:** the platform is `3298e70`, the
verification is the branch at `bf520ba`; neither covers the other.
Build chain: probe (`test` / `test-e2e`) **34421037502**, green in **19 s**
(creds 3/3, zone 4/4, state-backend 2/2) — **green where the page
documents red**: the teardown left the state backend behind, so the
state-backend check read 2/2 instead of the documented 2 FAIL. That is an
artefact of rebuilding a *used* account, not the fresh-account signature
the page describes → base **34421097160**, `apply-and-verify` success,
**2m55s** → management **34421376617**, success, **17m24s** → gate 1
`platform-cluster-claim` synced at `3298e70…`: XPlatformCluster
`platform/platform` published its four facts and the node group reached
Ready, about **24 minutes** from sync → gate 2 `spoke-access`, same SHA,
synced **01:20:40Z**: registration Secret `platform-spoke` present in hub
namespace `argocd` at **11 s**, carrying all six `k8-platform.io/*`
annotations exactly as documented; XSpokeAccess Ready=True at about
**6m10s**.
**Ordering that matters, measured:**
`identityproviderconfig/platform-5183a6d2c254` (owner
`XPlatformCluster/platform`) reached `Ready=True reason=Available` at
**01:13:50Z** and the composite at **01:14:17Z** — both **before** gate 2
was synced at **01:20:40Z**.
**Verification, measured by the fenced operator:** **17 Applications**, all
Synced/Healthy except `workload1-cluster` (OutOfSync by design) · hello
endpoint **HTTP 200 in 0.50 s**, body `hello from the k8-platform
platform-services cluster` · **Argo CD HTTP 200** · Keycloak **OIDC
discovery HTTP 200** with the expected issuer · five composites all
Synced=True Ready=True: `xplatformcluster`, `xspokeaccess`,
`xdatabase/keycloak-db` and two `xplatformsecret`.
**The storage ordering build #6 could NOT establish (bead `kp-2al.19`, now
closed):** StorageClass `gp3 (default)` / `ebs.csi.aws.com` age **6m57s**
against the three monitoring PVCs at **6m50s**, **6m22s** and **6m17s** —
the default class existed **before every PVC**, and all three bound on gp3
with **no retroactive assignment**. That is exactly the class-then-PVC
ordering build #6 had to leave `pending clean-build verification`.
**Oracle suite, two runs on this build** (sandbox, branch harness at or
before `bf520ba`, `LIVE_CLUSTER=k8-platform-services`,
`LIVE_PROFILE=full`, mode mutating):

- `build7-0135`: **pass=27 skip=0 fail=2**. **Zero skips is new** — the
  hub-targeting fix (`kp-ug3`) stopped three checks skipping structurally,
  so the two ArgoCD AppProject guards and the Crossplane RBAC scope guard
  executed at all for the first time. The two failures: the federation
  check's kubectl leg, and the AppProject destination guard.
- `build7-0152`: **pass=28 skip=0 fail=1**. **Federation PASSED** —
  `username=kc:oracle-build7-0152@federation-oracle.invalid
  groups∋kc:k8s-viewers`. Only the destination guard still failed.

Every row's build-#7 entry in the table below rests on that second run:
one check failed on `build7-0152` and it was the destination guard, so
every other check in the suite passed on this build.
**Both failures were diagnosed, and the diagnoses are part of the
evidence:**

1. **The destination-guard failure was a defect in the CHECK, not the
   platform** (`kp-2al.27`, fixed in commit `bf520ba`). A `platform-spoke`
   Application aimed at the hub was applied and watched for 120 s: the
   guard fired within **20 s** and stayed fired at every sample —
   `InvalidSpecError: application destination server
   'https://kubernetes.default.svc' and namespace 'default' do not match
   any of the allowed destinations in project 'platform-spoke'`. The check
   matched only "not permitted", which is Argo's *source repo* wording, so
   it was a **false negative that would have reported exactly the same had
   the guard been removed**. It had never executed on any build before
   `kp-ug3`'s fix let it run. (The 120-second Application was a deliberate
   negative control and was not a fix: nothing was mutated to make a check
   pass.)
2. **The federation failure was a timing window, not breakage.** An
   `ACTIVE` EKS identity-provider association does not immediately honour
   tokens: the kubectl leg was rejected at about **01:43Z** — with the
   brokered login and the id_token claims already passing at that same
   moment — and accepted at about **01:54Z**, roughly **ten to twenty-five
   minutes after the build**.

**live-verify (the recorded CI producer):** run **34428165725**, ref
`bf520ba353d4544339175076ea66dacbf49d2bcc`, `profile=full`, conclusion
**success**, evidence artifact **10133798389** uploaded **02:22:21Z**.
**Caveats on this build — recorded, not softened:**

- **The platform SHA and the verification SHA are not the same.** The
  platform was built from `main` `3298e70`; the oracle suite and
  live-verify ran the **branch** code (live-verify at ref `bf520ba`,
  which carries the harness fixes; the oracle runs at or before it, since
  the guard-check defect `bf520ba` fixes was still failing on them). Do
  not read either SHA as covering the other.
- **The probe was green where the documentation says red.** The teardown
  left the state backend in place, so the state-backend check read 2/2
  rather than the documented 2 FAIL — the signature of a rebuilt used
  account, not of a fresh one.
- **The bring-up was executed by a fenced agent, not a person.**
  `kp-2al.10` — a human executing this page on a fresh account —
  **remains open**, and the page keeps its `status: contract` marker.
- **The Argo CD browser sign-in is unverified.** Chromium cannot reach any
  host through this sandbox's proxy, so the fenced operator verified the
  admin credential through the `argocd` CLI against the same API instead.
  The browser experience was not exercised on this build.
- **The certificate the sandbox validated was the egress gateway's, not
  the ACM chain.** The operator's HTTPS goes through a TLS-intercepting
  egress gateway, so what its `curl` validated on the hello and Argo CD
  endpoints was the gateway's certificate. The public certificate is good
  transitively, but the **ACM chain was not directly verified from the
  sandbox** on this build.
- **The `kp-lc5` counter gap is settled by this build.** Both oracle runs
  printed the full summary line, and the counter agreed with the printed
  block on each: `build7-0135` read
  `pass=27 skip=0 fail=2 expect-full-violations=0 checks=29` and
  `build7-0152` read
  `pass=28 skip=0 fail=1 expect-full-violations=0 checks=29`, with no
  violation block printed on either — where build #6 read
  `expect-full-violations=0` while printing four violations and exiting 3.
- **The dry run produced nine documentation findings** (`kp-2al.23`
  through `kp-2al.26`), three of them serious — including that the page's
  **most emphatic warning was false**. The corrections are committed in
  `53b8cc0` and `1b94c01`.
- **Live mutations on this build, recorded rather than implied:** the two
  gate syncs (the documented deliberate-gate step, executed by the fenced
  agent from the sandbox), the mutating-mode oracle fixtures the suite
  creates and self-reaps by design, and the 120-second negative-control
  `platform-spoke` Application used to diagnose the destination guard.
  **None of them was a fix** — nothing was mutated to make a check or a
  feature pass. No broader "zero hand-mutation" claim is made here beyond
  that enumeration.

**Clean build #6 — 2026-09-09, rotated account `801822495028`** <!-- noqa: account-id - run provenance, account rotates -->
**(sixth consecutive from-scratch build; the IDENTITY build — rows 10 and 11
earn their first clean-build evidence and OI-2026-06-11-3 closes. NOT a
single-SHA build: the SHA map below says which SHA produced which evidence.)**
Region us-east-1; Route53 zone `Z08868662UCA0EHI3H5KH` /
`801822495028.realhandsonlabs.net`; <!-- noqa: account-id - run provenance, account rotates -->
hub EKS `k8-platform-mgmt`, spoke EKS `k8-platform-services`.
**SHA map (four SHAs, in order):** `bc1cbb6fe27b976dee0b4e86953114481ca15d51`
= `main` at build start and the explicit SHA both deliberate gates synced at ·
`18a4205292d64ff8b3946310c59801d24b5144ca` = the build-branch commit (Kyverno
removal) the base and management applies ran from; its `argocd/`, `clusters/`
and `crossplane/` trees are **byte-identical** to `bc1cbb6` (they differ only
under terraform/, tests/, docs/), which is what makes the gate syncs
legitimate clean-source syncs ·
`4364d4ae72e769f98ae657d65a23ff00fd775269` = the branch head for the
management re-apply that landed the widened verifier/reaper policy ·
`96279fd1d5a6fb5d852671e0211aa8c3e7fc9404` = the merge of PR #265 to `main`,
the revision every ArgoCD Application reports as synced and the SHA
live-verify and the live-evidence gate both ran against.
Build chain: creds probe **34396268449** (`main` @ `bc1cbb6`; Route53 zone
check 4/4 PASS, state-backend check 2 FAIL — head-bucket and describe-table
both 254 = the documented expected signature before bootstrap) → base
**34396955442** (branch @ `18a4205`, `apply-and-verify` success
19:45:34Z–19:48:57Z; bootstrapped the state backend) → management
**34397369089** (branch @ `18a4205`, success 19:49:39Z–20:10:57Z) →
management re-apply **34410469157** (branch @ `4364d4a`, success
22:06Z–22:07Z; the widened verifier/reaper policy) → gate 1
`platform-cluster-claim` synced by `kubectl patch` at the explicit SHA
`bc1cbb6`, `.status.sync.revision` observed equal to it afterwards — which
establishes that the Application's target revision was that SHA, **not**
that a sync operation completed at it (Argo sets that field from the target
revision it has observed, so it can already hold the right SHA before any
sync; the stronger `.status.operationState` check that would have proved a
completed sync at that SHA was not performed on this build — kp-2al.24,
found 2026-09-10): XPlatformCluster
`platform/platform` published `oidcIssuer`, `endpoint`, `clusterCaData` and
`certificateArn`, nodegroup `platform-78032583fa77` reached Ready, **15 min**
from sync → gate 2 `spoke-access`, same explicit SHA, `.status.sync.revision`
observed equal to it with the same caveat:
registration Secret `platform-spoke` appeared in hub namespace `argocd`
**within the first 30-second check**, carrying the full ADR-0010 contract
(all the `k8-platform.io/*` annotations; `config` decoding to
`awsAuthConfig.clusterName` = `k8-platform-services` plus 1492 bytes of
caData); XSpokeAccess Ready=True at 4m10s, XPlatformCluster Ready=True at
20m, 20:37:02Z. App stack at that convergence: every hub Application
Synced/Healthy except `spoke-observability-kube-prometheus-stack` (Degraded)
and `spoke-observability-loki` (Progressing) — the storage gap — and
`workload1-cluster` (OutOfSync by design). **No AWS or Kubernetes state was
hand-mutated at any point in this build.**
**The storage half (OI-2026-06-11-3):** after PR #265 merged to `main`, ArgoCD
auto-synced every Application to `96279fd` **with no manual step**, creating
the new `spoke-storage` Application (Synced/Healthy) and delivering the
composition change. Result on the spoke: `aws-ebs-csi-driver` addon ACTIVE,
version `v1.65.0-eksbuild.2`, under the composed IRSA role
`k8-platform-k8-platform-services-ebs-csi`; CSI driver `ebs.csi.aws.com`
registered; StorageClass `gp3 (default)`, provisioner `ebs.csi.aws.com`,
WaitForFirstConsumer, expandable; **all 3 monitoring PVCs Bound on gp3**; and
`spoke-observability-kube-prometheus-stack` + `spoke-observability-loki` both
went to **Healthy**. The gap is closed — with the PVC-ordering caveat below.
**Oracle suite on the merged `main`** (sandbox, RUN_ID `build6-2220`,
`LIVE_CLUSTER=k8-platform-services`, `LIVE_PROFILE=full`, mode **mutating**,
22:20Z–22:28Z): **pass=25 skip=3 fail=0 checks=28**. Every verdict: ACM
certificate ISSUED, all DNS DomainValidationOptions SUCCESS, CertificateValidation
completed · AccessEntry + AccessPolicyAssociation verified for
`k8-platform-mgmt-argocd` on `k8-platform-services`
(AmazonEKSClusterAdminPolicy) · `aws-ebs-csi-driver` addon ACTIVE under the
IRSA role (above) · EKS cluster `k8-platform-services` ACTIVE, node group
`k8-platform-services-default` ACTIVE · IdentityProviderConfig `keycloak` on
`k8-platform-services` ACTIVE with claims matching the `kc-*` binding
contract (issuer `https://auth.platform.<domain>/realms/platform`) · 3/3
ExternalSecrets Ready=True on the spoke · hello endpoint HTTP 200 with the
expected body marker after 1 s, hub-side `spoke-hello` Synced/Healthy · IAM
OIDC provider, cluster role, RolePolicyAttachment and ESO RolePolicy all
verified crossplane-provisioned · Keycloak OIDC discovery HTTP 200 with the
expected issuer, `spoke-keycloak` Synced/Healthy · XDatabase-provisioned RDS
instance `available` · Route53 ACM validation CNAME matches in zone
`Z08868662UCA0EHI3H5KH` · sandbox kubectl reached the spoke via the relay, 2
Ready nodes · PlatformSecret `k8-platform/keycloak/keycloak-oidc-clients`
exists with an AWSCURRENT version staged · spoke registration Secret carries
the full ADR-0010 contract · spoke storage: default gp3/`ebs.csi.aws.com`,
driver registered, 3/3 PVCs Bound · **federation (row 10): the broker chain
leaves Keycloak for the Cognito `/oauth2/authorize` endpoint; brokered login
issued an authorization code (the Cognito → Keycloak leg live); id_token
claims correct, `preferred_username=oracle-build6-2220@federation-oracle.invalid`,
groups ∋ `k8s-viewers`** · **federated kubectl (row 11):
`username=kc:oracle-build6-2220@federation-oracle.invalid
groups∋kc:k8s-viewers` on `k8-platform-services`** · IAM Role instantiate
converged and verified by tag · Secrets Manager instantiate converged, real
ASM secret `k8-platform/live-verify-build6-2220` verified by tag · IAM
resource-scope negative guards fired as designed, with positive controls.
**live-verify (the recorded CI producer):** run **34412419016**, `main` @
`96279fd`, `profile=full`, success, emitting verbatim
`{"run_id": "34412419016", "sha": "96279fd1d5a6fb5d852671e0211aa8c3e7fc9404", "account": "801822495028", "cluster": "k8-platform-mgmt", "profile": "full", "conclusion": "success", "created_at": "2026-09-09T22:43:28Z"}` <!-- noqa: account-id - run provenance, account rotates -->
— and the fail-closed **live-evidence gate** run **34414013044** (`main` @
`96279fd`) read that evidence as satisfying: success.
**Caveats on this build — recorded, not softened:**

- **Not a single-SHA build.** Terraform applied from branch `18a4205` (later
  `4364d4a`); the gates synced `main` @ `bc1cbb6`; the storage half only
  became live after the merge to `96279fd`. The GitOps paths were
  byte-identical between `18a4205` and `bc1cbb6`, which is why the gate syncs
  are legitimate clean-source syncs — but no single SHA produced all of the
  evidence above.
- **The merge to `main` preceded the live evidence for the storage change, by
  an explicit one-time owner exception granted 2026-09-09.** Reason: ArgoCD
  auto-syncs `crossplane/` and `argocd/` from `main` with selfHeal, so a
  composition change can never be live while it is only on a branch, while
  `live-evidence-verify` demands a full live-verify pass at the pushed SHA — a
  circularity. The exception was granted on the condition that the change be
  backed out of `main` immediately if it did not work; it worked, so nothing
  was backed out. **This is an exception, not a precedent, and the underlying
  circularity is still open.**
- **The row-10/row-11 evidence comes from the POST-FIX oracle run.** An
  earlier run on this same build, RUN_ID `build6-2042`, was pass=21 skip=4
  **fail=1**. Both bad results were defects in the checks, not in the
  platform, and both were fixed in this build's own commits: `kp-8vs` (the
  federation check read only the first redirect hop, so it could never pass,
  and its skip text blamed a realm-import ordering race the evidence ruled
  out) and `kp-7ei` (the Secrets Manager check set an external-name
  annotation that is inert for that kind, so the provider asked AWS for a
  `terraform-`prefixed name the correctly scoped policy denied — CloudTrail
  showed AccessDenied retried through the whole 300 s window).
- **The PVCs on this build predated the default StorageClass.** They had been
  created unclassed while no default existed and bound retroactively once gp3
  arrived. A from-scratch build creates them after the class exists, so the
  class-then-PVC ordering is **not** what this build proved: that ordering is
  **pending clean-build verification**.
- **The suite still exits 3** over four kinds its derived expect-full list
  declares but no check verifies: `ec2.aws.m.upbound.io/SecurityGroup`,
  `generators.external-secrets.io/Password`,
  `rds.aws.m.upbound.io/SubnetGroup`,
  `secretsmanager.aws.m.upbound.io/SecretVersion`. The printed summary counter
  contradicts that by reading `expect-full-violations=0` (bead `kp-lc5`). CI's
  explicit `LIVE_EXPECT_FULL` list is a different, 14-kind list, which is why
  live-verify passed. **Open gap, not a pass.**
- **Three checks skipped structurally** because hub-fixture checks read the
  single spoke-targeted `LIVE_CLUSTER` (bead `kp-ug3`): the two ArgoCD
  AppProject guards and the Crossplane RBAC scope guard.
- Two gate syncs and the sandbox oracle run were human/agent-initiated from
  the sandbox. The gate syncs are the documented human gate step, not
  out-of-band mutation.

**Clean build #5 — 2026-07-05/06, fresh account `975050361443`** <!-- noqa: account-id - run provenance, account rotates -->
**(fifth consecutive from-scratch build; the EVIDENCE build — every oracle
recorded, live-verify's first honest green, the OI-2026-06-12-1 close).**
Source: merged `main` (`b85d7f2` for the terraform phases; the deliberate
gates pulled at `0739c5e` = `b85d7f2` + the docs-only #254 — identical
platform manifests). Build chain: creds probe **28757370347** (expected
shape: fresh account + un-bootstrapped state backend) → base
**28757434684** → management **28757800712** (both `apply-and-verify`
green **on the first attempt** — the #245 kubeconfig-race fix's first
clean pass; ~17 min) → `platform-cluster-claim` synced by explicit SHA
via the SSM relay (XR Synced+Ready in **21 min**) → `spoke-access` synced,
registration Secret complete on its own → full spoke stack Synced+Healthy
(eso / external-dns / hello / ingress-nginx / **keycloak**; observability
pair = the known OI-2026-06-11-3; workload1 OutOfSync by design). The
ADR-0012 material chain converged from committed source: both
XPlatformSecret XRs up, SecretVersion staged AWSCURRENT, Keycloak booted
on the cross-cluster keycloak-admin pull. **Zero manual steps.**
Oracles on this build (sandbox, RUN_ID `build5-2347`): `hello-e2e-live`
PASS (HTTP 200 + marker in 21 s; hub `spoke-hello` Synced+Healthy) ·
`spoke-cluster-secret-live` PASS (full ADR-0010 contract) ·
`sandbox-kubectl-relay` PASS (spoke, 2 Ready nodes) · `rds-instance-live`
PASS (instance `available` in the base VPC) · `keycloak-e2e-live` PASS
(OIDC discovery 200, https issuer, first poll; hub `spoke-keycloak`
Synced+Healthy) · `secretsmanager-secret-live` PASS — **the material
chain's FIRST oracle-recorded evidence** (AWSCURRENT staged on
`k8-platform/keycloak/keycloak-oidc-clients`).
**live-verify.yml (the recorded CI producer):** the first dispatch on
`main` (run **28759141867**) went RED and the red was REAL — under the
scoped verifier role three read verbs were missing and two checks
reported the denied reads as world state (a false OI-2026-06-11-1
placement-bug FAIL + false "not provisioned" skips). Same run: 10 checks
PASS under the scoped role, including `secretsmanager-secret-live`.
Fixed same-session code-not-hands (policy verbs + check-honesty hardening
+ `test_verifier_policy_covers_check_reads.sh` enforcing the whole class),
applied by management run **28759438992** (branch, green) → live-verify
run **28760138628** (branch = `main` + that fix set) **GREEN
with `secretsmanager.aws.m.upbound.io/Secret` + `iam OpenIDConnectProvider`
+ `iam RolePolicy` promoted into the producer's expect-full list** — the
fail-closed live-evidence PR gate has its first producer, and
OI-2026-06-12-1 is CLOSED.

**Clean build #4 — 2026-07-05, fresh account `211125323087`** <!-- noqa: account-id - run provenance, account rotates -->
**(the material-chain bring-up; account expired before the oracles ran —
its oracle evidence rides build #5 above).** Source: merged `main`
(`b2880a9` → `145ea6e` via the four first-live-exercise defect fixes
merged mid-build by GitOps propagation: #245 kubeconfig truncate race,
#248 producer-RBAC bootstrap ordering, #250 tag charset, #251
`secretsmanager:GetResourcePolicy`). Build chain: probe **28744551280** →
base **28746752536** → management **28750304494** (+ final policy apply
**28755969208**) → both deliberate gates pulled → spoke registered, app
stack converged, **both XPlatformSecret XRs Synced+Ready observed live
21:57Z**: the platform generated material, AWSCURRENT written into the
deterministic containers, the spoke pulled the cross-cluster key, Keycloak
BOOTED on it (ADR-0012 end-to-end live, first time). Per this file's own
rule the row entries below cite builds #1–#3 and #5 — build #4's
convergence was observed but not oracle-recorded before the account died.

**Clean build #3 — 2026-06-12, fresh account `798802785871`** <!-- noqa: account-id - run provenance, account rotates -->
**(third consecutive from-scratch build; first with the full keycloak stack).**
Source: merged `main` (`0dd6114` = post-PR-#227). Build chain: base = CI run
**27429951073**, management = CI run **27430525986** (both `apply-and-verify`
green; the credential probe **27429228144** first confirmed the GHA secrets
resolve to the new account) → `platform-cluster-claim` synced from `main`
(`argocd app sync --core` via the SSM relay; XR Ready ~21 min) →
`spoke-access` synced from `main`, **no patches** (registration Secret
complete on its own, full ADR-0010 contract). Oracles on this build:
`hello-e2e-live.sh` PASS (HTTP 200 first poll), `spoke-cluster-secret-live.sh`
PASS, `sandbox-kubectl-relay.sh` (spoke, 2 Ready) PASS, `rds-instance-live.sh`
PASS (instance in the BASE VPC — the OI-2026-06-11-1 CREATE-path close; the
oracle's own bool-case false negative fixed in #235), **and NEW:
`keycloak-e2e-live.sh` PASS** — Keycloak booted against RDS through the spoke
ingress (https OIDC issuer; the OI-2026-06-07-5 behavioral close). The
keycloak first boot surfaced four committed defects; per the
code-not-hands loop each was fixed in code with a red-first unit test and
merged mid-build (#231 admin-ES revert gap, #232 realm-JSON comment fields,
#233 placeholder IdP URLs, #234 KC_HOSTNAME https issuer), reaching the
spoke by GitOps propagation only. Zero manual steps; operator inputs were
the two designed deliberate-sync gates.

**Clean build #2 — 2026-06-11, fresh account `608553548146`** <!-- noqa: account-id - run provenance, account rotates -->
**(the green-twice gate is now satisfied).** Source: merged `main`
(`582761f`), no mid-build merges needed for the gate rows. Build chain:
base = CI run **27379934113**, management = CI run **27380296208** (both
`apply-and-verify`, green), spoke = ArgoCD sync of `platform-cluster-claim`
from `main` (XR `platform` Ready=True in ~14 min) then `spoke-access` from
`main` with **no oidcIssuer patch** (the Observe path supplied it; the
registration Secret appeared complete on its own ~3 min after sync — all 3
labels + all 5 contract annotations). Terminal state:
`https://hello.platform.<domain>` → **HTTP 200, verified public chain**
(first poll), with the committed oracles passing on this build:
`hello-e2e-live.sh` PASS, `spoke-cluster-secret-live.sh` PASS,
`sandbox-kubectl-relay.sh` (spoke, 2 Ready nodes) PASS. Zero manual steps;
the only operator inputs were the two designed deliberate-sync gates.
New on this build: the `keycloak-db` XDatabase auto-synced and **provisioned
RDS from scratch under the fully narrowed IAM policy** (XR Ready=True,
`rds-instance-live.sh` PASS) — rows 6 and 7 earn their first CREATE-path
evidence. The build loop also caught a NEW defect (**OI-2026-06-11-1**: the
RDS Instance lands in the account DEFAULT VPC — unreachable from the
platform clusters; durable Composition+EnvironmentConfig fix authored in PR
#226, the same code-not-hands loop as OI-2026-06-10-1 on build #1).

**Clean build #1 — 2026-06-10, fresh account `341221860475`** <!-- noqa: account-id - run provenance, account rotates -->
**(the first ever from-scratch build with zero manual steps).** Source: merged
`main` (`a68b858` = PRs #220/#221/#222 + prior; the mid-build Composition fix
#223 `c8fddb8` reached the hub by GitOps propagation, not hand-edit). Build
chain: base = CI run **27305258998**, management = CI run **27305788371**
(both `apply-and-verify`, green), spoke = ArgoCD sync of
`platform-cluster-claim` then `spoke-access` from committed `main` (the two
designed deliberate-sync gates; **no value overlays, no REST registration, no
aws-CLI mutations, no kubectl applies**). Terminal state:
`https://hello.platform.<domain>` → **HTTP 200, verified public chain**, with
the committed oracles passing on this build: `hello-e2e-live.sh` PASS,
`spoke-cluster-secret-live.sh` PASS, `sandbox-kubectl-relay.sh` (spoke) PASS.

| # | Item / known gap | Durable fix | Clean-build evidence | Status |
|---|---|---|---|---|
| 1 | EKS service-linked-role `iam:GetRole` (zero-node spoke) | PR #213 (committed `irsa.tf`) | Builds #1–#3: the spoke nodegroup created from scratch under the committed narrowed policy on three consecutive fresh accounts — 2 Ready nodes each (`sandbox-kubectl-relay.sh` PASS all three). (The earlier auto-016 "VALIDATED" stays retracted — see `retrospective/2026-06-09-214-a.md`.) Build #5: 2 Ready nodes again (relay oracle PASS, RUN_ID build5-2347). Build #6: 2 Ready nodes again on the rotated account (relay oracle PASS, RUN_ID build6-2220). Build #7: the spoke node group was created from scratch again on the emptied-and-rebuilt account and reached Ready (gate 1, ~24 min from sync); the relay oracle PASSED again (RUN_ID `build7-0152`, pass=28 skip=0 fail=1, the one failure being a CHECK defect — see the build-#7 block). | **DONE (6× clean build)** |
| 2 | Hub→spoke EKS-API SG 443 (OI-2026-06-07-4) | `hub-eks-api-ingress` classic SecurityGroupRule (PR #221) | Builds #1–#3: hub ArgoCD synced every spoke-* Application on the spoke's private endpoint with zero SG hand-fixes on all three accounts; `hello-e2e-live.sh` asserts `spoke-hello` Synced+Healthy from the hub (PASS all three). Build #5: PASS again (200 in 21 s). Build #6: PASS again (200 + marker in 1 s; the hub synced every spoke-* Application on the spoke's private endpoint with zero SG hand-fixes). Build #7: PASS again — hello HTTP 200 in 0.50 s with the body marker, and the hub synced all 17 Applications (hub-side `spoke-hello` Synced/Healthy) on the spoke's private endpoint with zero SG hand-fixes (RUN_ID `build7-0152`). | **DONE (6× clean build)** |
| 3 | Shared ELB subnet tags (OI-2026-06-07-3) | terraform/base `hosted_cluster_names` tags (PR #222) | Builds #1–#3: the spoke ingress NLB provisioned in the shared subnets with zero `create-tags` hand-fixes on all three accounts (hello 200 terminates on that NLB with the spoke's ACM cert). Build #5: same, zero hand-fixes. Build #6: same, zero `create-tags` hand-fixes — hello 200 terminates on the spoke's NLB with its ACM cert (certificate ISSUED, all DomainValidationOptions SUCCESS, validation CNAME matched in zone Z08868662UCA0EHI3H5KH). Build #7: same again on the rebuilt account, zero `create-tags` hand-fixes — hello 200 terminates on the spoke's NLB and the suite's certificate checks passed (RUN_ID `build7-0152`). Caveat: the fenced operator's `curl` ran through a TLS-intercepting egress gateway, so the chain it validated was the gateway's — the ACM chain itself was not directly verified from the sandbox on this build. | **DONE (6× clean build)** |
| 4 | Placeholder overlays vs bootstrap selfHeal (OI-2026-06-07-2, **ADR-0010**) | ApplicationSets consumer half (PR #218) + row-5 producer | Builds #1–#3: all seven ApplicationSets generated from the registration Secret's contract annotations on all three accounts; spoke-hello/-ingress-nginx/-external-dns Synced+Healthy with **no hand overlay anywhere**. Build #5: all seven again, incl. keycloak. Build #6: generated again from the contract annotations with no hand overlay anywhere — including the NEW `spoke-storage` ApplicationSet, whose Application came up Synced/Healthy off the same labeled cluster Secret after the merge to `96279fd`. Build #7: generated again from the contract annotations with no hand overlay anywhere — 17 Applications, all Synced/Healthy except `workload1-cluster` (OutOfSync by design), `spoke-storage` among them from the start of the build rather than after a merge. **And the spoke-storage ordering build #6 could not establish is now evidenced:** default class `gp3`/`ebs.csi.aws.com` age 6m57s against the three monitoring PVCs at 6m50s, 6m22s and 6m17s — the class existed before every PVC and all three bound on gp3 with no retroactive assignment (bead `kp-2al.19` closed; build #6's ordering caveat retired). | **DONE (6× clean build)** |
| 5 | Spoke ArgoCD cluster-Secret durable form (OI-2026-06-07-1) | ADR-0010 PR-2 producer (PR #220; retires the spec.oidcIssuer overlay) | Builds #1–#3: `platform-spoke` Secret produced by the Composition (Observe→writer Objects), full contract real on all three accounts; `spoke-cluster-secret-live.sh` PASS all three; ArgoCD connection Successful (apps synced through it). Build #5: PASS again (full contract). Build #6: PASS again — `platform-spoke` complete on its own within the FIRST 30-second check (full contract; `config` → `awsAuthConfig.clusterName` = `k8-platform-services` + 1492 bytes caData), apps synced through it. Build #7: PASS again — `platform-spoke` present in hub namespace `argocd` at **11 s** with all six `k8-platform.io/*` annotations exactly as documented, and the full 17-Application stack synced through it (RUN_ID `build7-0152`). | **DONE (6× clean build)** |
| 6 | RDS narrowing safe on the CREATE path (#211) | PR #211 (committed) | Clean build #2: `keycloak-db` auto-synced from `main` and provisioned RDS from scratch under the narrowed policy (XR Synced+Ready=True ~10 min, `rds-instance-live.sh` PASS, instance `available`). Caveat (build #2): the instance landed in the DEFAULT VPC (OI-2026-06-11-1). Build #3: fresh CREATE landed directly in the BASE VPC under the merged #226/#227 fix (`rds-instance-live.sh` PASS after the #235 oracle bool fix) and Keycloak CONNECTS through it (`keycloak-e2e-live.sh` PASS — the OI-2026-06-07-5 close). Build #5: fresh CREATE in the base VPC again, `rds-instance-live.sh` PASS. Build #6: fresh CREATE again under the narrowed policy, `rds-instance-live` PASS (XDatabase-provisioned instance `available`, RUN_ID build6-2220) and Keycloak connects through it. Build #7: fresh CREATE again under the narrowed policy, this time from an account verified to hold zero RDS instances beforehand — `xdatabase/keycloak-db` Synced=True Ready=True, `rds-instance-live` PASS, and Keycloak connects through it (OIDC discovery 200; RUN_ID `build7-0152`). | **DONE (5× clean build)** |
| 7 | EC2 narrowing safe on the CREATE path (#212) | PR #212 (committed) | Clean build #2: management run 27380296208 applied the EC2VpcScoped/EC2Unconditioned Sids; the spoke's kube-relay-ingress + hub-eks-api-ingress SecurityGroupRule MRs created under them (relay oracle PASS = the rules function; hub→spoke sync = the API rule functions). Build #3 (run 27430525986): same CREATE path green again, plus the XDatabase SecurityGroup + 5432 rule created from scratch (the rds:5432 path keycloak now traverses). Build #5: same CREATE path green again (mgmt run 28757800712). Build #6: same CREATE path green again (mgmt run 34397369089, re-apply 34410469157) — relay oracle PASS (the kube-relay rule functions) and the hub synced every spoke app over the private endpoint (the API rule functions). Build #7: same CREATE path green again in a single management apply (run 34421376617, 17m24s, no re-apply) — relay oracle PASS and the hub synced all 17 Applications over the spoke's private endpoint (RUN_ID `build7-0152`). | **DONE (5× clean build)** |
| 8 | Hello hub→spoke e2e (OI-2026-06-08-2) | PR #210 (check authored) | Builds #1–#3: PASS on all three accounts (HTTP 200 + body marker + hub-side `spoke-hello` Synced+Healthy; 1s to first 200 on builds #2+#3). Build #5: PASS (21 s). Build #6: PASS (HTTP 200 + body marker after 1 s; hub-side `spoke-hello` Synced/Healthy; RUN_ID build6-2220). Build #7: PASS (HTTP 200 in 0.50 s, body `hello from the k8-platform platform-services cluster`; hub-side `spoke-hello` Synced/Healthy; RUN_ID `build7-0152`). | **DONE (6× clean build)** |
| 9 | Keycloak **boots** against RDS through the spoke ingress (OI-2026-06-07-5) | cross-cluster DB path (hub PushSecret → ASM → spoke ExternalSecret + extraEnvVarsSecret host/port) | Clean build #3: `keycloak-e2e-live.sh` PASS — realm imports, https OIDC discovery 200. Four first-boot defects fixed in code mid-build (#231–#234). Build #5: `keycloak-e2e-live.sh` PASS again — and the DB path now rides the ADR-0012 material chain end-to-end (its first oracle-recorded build). Build #6: PASS again on the rotated account (OIDC discovery 200 with the expected issuer, hub `spoke-keycloak` Synced/Healthy, RUN_ID build6-2220) — and this is the build where the realm's Cognito broker imported (row 10). Build #7: PASS again on the emptied-and-rebuilt account — Keycloak booted against a freshly created RDS instance and OIDC discovery answered HTTP 200 with the expected issuer, `xdatabase/keycloak-db` and both XPlatformSecret composites Synced=True Ready=True (RUN_ID `build7-0152`). | **DONE (4× clean build)** |
| 10 | Keycloak **federation live-wired** to Cognito (REQ-AUTH-02/08) | BUILT 2026-07-06 (this branch): the broker + mappers are back in the realm as `${KC_COGNITO_*}` env placeholders substituted at `--import-realm` (mechanism verified empirically on the pinned Keycloak 24.0.5); delivery = terraform/base → ASM `k8-platform/base/cognito` → spoke ES → NON-optional secretKeyRef env (fail-closed, the #233 class prevented by construction). Contract pinned by `test_keycloak_cognito_idp_contract.sh`; committed realm boot-verified in docker. NOTE: a live realm never re-imports (IGNORE_EXISTING) — first live exercise is the next from-scratch build. | Realm import runs only on a fresh Keycloak DB ⇒ evidence must come from a clean build with this merged; the federation oracle (`cognito-federation-live.sh`) records it. Hosted-UI leg live-verified standalone on build #5. Post-merge retrofit (2026-07-06, build-#5 cluster): the DELIVERY chain proved live — base apply 28761827039 staged ASM `k8-platform/base/cognito`, spoke ES synced 12 s later (8-key Secret), both KC pods rolled with the fail-closed `KC_COGNITO_*` env; broker confirmed ABSENT in the live realm via the admin API (IGNORE_EXISTING, as documented) — the import half is exactly what build #6 must evidence. A live-drift defect in the new ES manifest (three ESO CRD-default enums omitted from `dataFrom[].extract`) was found and fixed red-first this branch (L40 lint). **Clean build #6 (2026-09-09, rotated account — see the build-#6 block above) is the flip:** the realm imported on a fresh Keycloak DB from committed source (delivery rode base apply **34396955442** → ASM `k8-platform/base/cognito` → spoke ES → fail-closed `KC_COGNITO_*` env), and the federation oracle PASSED on that build (sandbox, RUN_ID `build6-2220`, `LIVE_PROFILE=full`, mode mutating, 22:20Z–22:28Z, against merged `main` `96279fd`): the broker chain leaves Keycloak for the Cognito `/oauth2/authorize` endpoint, brokered login issued an authorization code (the Cognito → Keycloak leg live), id_token claims correct — `preferred_username=oracle-build6-2220@federation-oracle.invalid`, groups ∋ `k8s-viewers`. Two caveats recorded with it: the evidence is from the POST-FIX oracle run (the earlier `build6-2042` run was fail=1 on a defect in the CHECK — it read only the first redirect hop, bead `kp-8vs`, fixed in this build's own commits), and build #6 is not a single-SHA build (SHA map in the build-#6 block). **Clean build #7 (2026-09-10, the same account emptied to nothing and rebuilt — see the build-#7 block) is the second, and it retires the not-a-single-SHA caveat on the platform half:** the realm imported the broker on a fresh Keycloak DB again, in a build whose probe, base apply, management apply and BOTH gate syncs all ran one `main` SHA (`3298e70f614d793f040ea4d6b97c4455cfe028b9`), and the federation oracle PASSED on it — sandbox RUN_ID `build7-0152`, `LIVE_PROFILE=full`, mutating, pass=28 skip=0 fail=1 (the single failure an unrelated CHECK defect, `kp-2al.27`): `username=kc:oracle-build7-0152@federation-oracle.invalid groups∋kc:k8s-viewers`. Two caveats ride build #7 in place of the retired one: the oracle suite ran the **branch** harness, not the platform's `3298e70` (live-verify ran ref `bf520ba353d4544339175076ea66dacbf49d2bcc`), so one SHA still does not cover both halves of the evidence; and the earlier run on this same build (`build7-0135`) failed the federation check's kubectl leg on a **timing window, not breakage** — an `ACTIVE` EKS identity-provider association does not immediately honour tokens: rejected ~01:43Z with the brokered login and the id_token claims passing at that same moment, accepted ~01:54Z, roughly 10–25 min after the build. | **DONE (2× clean build: #6, #7)** |
| 11 | EKS clusters federate kubectl auth to Keycloak (REQ-AUTH-07/09/10) | BUILT 2026-07-06 (this branch): `IdentityProviderConfig` composed into the platform-cluster Composition (resource 16 — clientId `kubernetes`, `preferred_username`/`groups`, both prefixed `kc:`, issuer combined from the same env pair as the ACM cert + KC_HOSTNAME; external-name `keycloak`). Ships with its coverage-oracle entry, live check, claim-contract unit test, regenerated render golden, and CRD schema. The REQ-AUTH-10 federation oracle (`cognito-federation-live.sh`) drives the whole path headlessly with a self-reaped directory fixture user. | **Post-merge observed live 2026-07-06** on the build-#5 cluster: the XR gained the association by GitOps auto-sync and it reached ACTIVE — `eks-identity-provider-config-live` PASS, composite XR Ready=True (no wedge). That proves the EKS-side half live, but is NOT clean-build evidence: the realm broker (rows-10 half) only imports on a fresh Keycloak DB, so the composed-from-scratch + federation-oracle evidence still records on the next clean build. **Clean build #6 (2026-09-09) records it:** the IdentityProviderConfig `keycloak` on `k8-platform-services` was composed from scratch and reached ACTIVE with claims matching the `kc-*` binding contract (issuer `https://auth.platform.<domain>/realms/platform`), and federated kubectl PASSED on that build — `username=kc:oracle-build6-2220@federation-oracle.invalid groups∋kc:k8s-viewers` on `k8-platform-services` (RUN_ID `build6-2220`, mutating, against merged `main` `96279fd`). Same two caveats as row 10: post-fix oracle run, and build #6 is not a single-SHA build. **Clean build #7 (2026-09-10) records it a second time and retires the single-SHA caveat on the platform half:** `identityproviderconfig/platform-5183a6d2c254` (owner `XPlatformCluster/platform`) was composed from scratch in a build that ran one `main` SHA (`3298e70`) end to end and reached `Ready=True reason=Available` at **01:13:50Z**, with the composite Ready at **01:14:17Z** — both **before** gate 2 was synced at **01:20:40Z**, so the association neither waits on the spoke-access gate nor wedges the composite. Federated kubectl PASSED on `build7-0152`: `username=kc:oracle-build7-0152@federation-oracle.invalid groups∋kc:k8s-viewers` on `k8-platform-services`. Caveats as in row 10: the oracle suite ran the branch harness, not the platform's `3298e70` (live-verify ran ref `bf520ba`); and an `ACTIVE` association does not honour tokens immediately (the `build7-0135` kubectl leg was rejected ~01:43Z and accepted ~01:54Z — a warm-up window, not breakage). | **DONE (2× clean build: #6, #7)** |

Clean build #1 also caught and durably fixed a NEW defect mid-build —
**OI-2026-06-10-1** (ACM provider v2.5.0 leaves the Certificate external-name
empty; `certificateArnSelector` could never resolve; fixed in PR #223 by
routing the ARN through the composite) — which is the build loop working as
designed: the failure produced a code fix, not a hand-fix.

**No row may flip to DONE without filling its evidence column.** The agent does not
get to assert these are fixed; you (or anyone) can audit each one by clicking the
run ID.

---

## The order of operations to actually finish

1. ~~Build the four missing durable fixes (#2–#5).~~ **DONE** (PRs #218/#220/#221/#222).
2. ~~Integration branch + rebuild from committed source with ZERO manual steps.~~
   **DONE ONCE** — clean build #1 above (2026-06-10). The mid-build defect it
   caught (OI-2026-06-10-1) was fixed in code (PR #223) and converged by GitOps.
3. ~~Second green clean build.~~ **DONE** — clean build #2 above (2026-06-11,
   account 608553548146): same recipe, zero manual steps, all three oracles <!-- noqa: account-id - run provenance, account rotates -->
   PASS. **The green-twice posture gate is satisfied.**
4. ~~Rows 6/7 (RDS/EC2 narrowing on the CREATE path) + OI-2026-06-07-5
   keycloak DB path.~~ **DONE** — clean build #3 (2026-06-12, account
   798802785871): RDS in the base VPC, Keycloak boots against it, row 9 <!-- noqa: account-id - run provenance, account rotates -->
   earned. Rows 6/7 now 2×.
5. ~~Phase-5 identity half (rows 10/11) — build the feature.~~ **BUILT**
   (2026-07-06, the clean-build-5-evidence branch): broker + mappers +
   EKS IdP config + the federation oracle, contract-docs-first per the
   documentation plan. Rows 10/11 flip on the next clean build's recorded
   evidence — a live realm never re-imports, so build #6 is the earliest
   honest flip. **FLIPPED** on clean build #6 (2026-09-09): the realm
   imported the broker on a fresh Keycloak DB and the federation oracle
   PASSED (RUN_ID `build6-2220`), rows 10/11 now DONE.
6. ~~The live-evidence producer green so the PR gate flips.~~ **DONE**
   (build #5): live-verify green with secretsmanager/Secret + iam
   OIDC/RolePolicy in expect-full; the fail-closed PR gate has its first
   producer. Remaining test-overhaul work (SKIP-kind flips, Track B)
   proceeds from here.
7. ~~Clean build #6: rows 10/11 + the OI-2026-06-11-3 storage gap.~~
   **DONE** — clean build #6 above (2026-09-09, rotated account): rows 10
   and 11 flipped on recorded oracle evidence (RUN_ID `build6-2220`),
   live-verify **34412419016** green and the fail-closed live-evidence gate
   **34414013044** read it as satisfying, and the spoke now ships the EBS
   CSI addon + default gp3 StorageClass with all 3 monitoring PVCs Bound
   and both observability Applications Healthy. Still owed out of this
   build, carried as blockers rather than buried: the class-then-PVC
   ordering (**pending clean-build verification** — these PVCs predated the
   class), the suite's exit-3 expect-full gap and its contradicting summary
   counter (`kp-lc5`), the three structural hub-fixture skips (`kp-ug3`),
   and the merge-before-live-evidence circularity the one-time owner
   exception papered over.

8. ~~Clean build #7: the class-then-PVC ordering + the documentation as the
   only instruction set.~~ **DONE** — clean build #7 above (2026-09-10, the
   same account emptied to nothing and rebuilt), executed by a **fenced
   agent** that could read only
   `docs/site/how-to/build-the-platform-from-nothing.md`. It earned: the
   **storage ordering** build #6 could not establish (default gp3 class
   6m57s old against PVCs at 6m50s/6m22s/6m17s — `kp-2al.19` closed), a
   second recording for rows 10 and 11 with build #6's not-a-single-SHA
   caveat retired on the platform half (one `main` SHA `3298e70` for probe,
   both applies and both gate syncs), **zero structural skips** for the
   first time (`kp-ug3`'s hub-targeting fix let the two AppProject guards
   and the Crossplane RBAC scope guard execute at all), and live-verify
   **34428165725** success at ref `bf520ba` with evidence artifact
   **10133798389**. Still owed out of this build, carried as blockers
   rather than buried: a **human** executing the page on a **fresh**
   account (`kp-2al.10`, still open — the page keeps its `status: contract`
   marker); the Argo CD **browser** sign-in (unverifiable from this
   sandbox — Chromium has no egress; the credential was checked through the
   `argocd` CLI instead); direct **ACM chain** validation from the sandbox
   (the TLS-intercepting egress gateway stands in the way); the `kp-lc5`
   expect-full gap, which these runs did not record either way and which
   therefore stays `pending clean-build verification`; and the
   merge-before-live-evidence circularity from build #6, untouched.

9. ~~Clean build #9: the ops box drives the bring-up.~~ **DONE** — clean
   build #9 above (2026-09-12, a new account): `terraform/opsbox` applied by
   its own workflow on a fresh account, its self-test green, and
   `scripts/opsbox/k8p-bringup.sh` took the platform from base to a serving
   hello endpoint with the operator's part reduced to four workflow
   dispatches. It found two optimistic-direction defects in the driver's own
   checks (base declared applied mid-apply; the endpoint declared down on a
   stale negative DNS cache) and fixed both with tests before the bead
   closed. Still owed: a **human** executing the rewritten page on a fresh
   account (`kp-2al.10`, the page keeps `status: contract`); the browser
   shell opened by a person from the console (the build reached the box over
   the same Systems Manager channel by `send-command`); the ops-box
   `destroy` action on an account that also carried a platform.

A fix that cannot be validated this way stays `pending clean-build
verification` and is carried as a **blocker**, not silently deferred into the
open-issues graveyard.
