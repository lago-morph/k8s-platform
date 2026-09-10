---
status: contract
---

# Build the platform from a workstation (alternative, unverified)

A copy/paste Terraform runbook for building the platform from your own
machine instead of from CI. It exists because the platform's two
imperative layers are ordinary Terraform modules and an operator with
credentials and a checkout should be able to run them.

!!! warning "Alternative path — never executed by a person, unverified"
    **This is not the supported way to build the platform.** The
    supported path is
    [Build the platform from nothing](build-the-platform-from-nothing.md):
    two workflow runs plus the two gate syncs, which is what every
    clean build of this platform has actually used.

    The steps below are assembled from the same committed Terraform the
    CI path applies — each one cites its module — but **no person has
    ever run them end to end**, and no build has ever been verified
    through them. Treat every command here as unverified. Read it to
    understand the layers, or to recover a situation CI cannot reach;
    do not automate against it, and do not treat a result obtained this
    way as evidence that the platform builds.

    A human-executed run of this page, on a fresh account, is what would
    flip it to `stable`.

## How this differs from the supported path

| | Supported path (CI dispatch) | This page (workstation) |
|---|---|---|
| Who has run it | Every clean build to date | Nobody |
| Terraform state backend | Bootstrapped automatically from the account ID | You create and name it, and pass it by hand |
| Domain and hosted zone | Discovered from the account | You supply both in `terraform.tfvars` |
| Cognito test credentials | Generated fresh per run, never committed | You write them into `terraform.tfvars` |
| Verification of each layer | Workflow verify steps assert the result and fail loudly | You run the checks yourself |
| Terraform *content* applied | identical | identical |
| The two gates | identical — same two Applications, same two syncs | identical |

The Terraform is the same Terraform. What the CI path adds is the
wiring around it and a verification step that has caught real failures.

## Before you start

- An AWS account with administrator-grade credentials in your
  environment, in a supported region (`us-east-1` by default).
- A **domain with a Route53 hosted zone**. The platform discovers the
  zone; it does not create your domain. (On sandbox accounts with a
  pre-created zone, you will supply its zone ID below.)
- An **S3 bucket and DynamoDB lock table for Terraform state**, which
  you create or choose — state lives outside the platform by design so
  the management layer can always be rebuilt or recovered.
- CLI tools: `terraform` (≥ 1.6), `kubectl`, `helm`, `aws`, `argocd`,
  `git`, `curl`.
- A clone of the platform repository, on `main`.

## 1. Base environment (`terraform/base`)

Networking, DNS wiring, and the identity substrate.

```bash
cd terraform/base
cp terraform.tfvars.example terraform.tfvars
# edit: domain, aws_region, availability_zones,
#       route53_zone_id (sandbox accounts), cognito test user
terraform init \
  -backend-config="bucket=<your-state-bucket>" \
  -backend-config="key=base/terraform.tfstate" \
  -backend-config="region=<region>" \
  -backend-config="dynamodb_table=<your-lock-table>"
terraform plan
terraform apply
```

Never commit `terraform.tfvars` — every account-specific value stays
out of Git.

## 2. Management cluster (`terraform/management`)

The hub: EKS plus the GitOps controller and the infrastructure engine,
and the **last step you perform imperatively**.

```bash
cd terraform/management
cp terraform.tfvars.example terraform.tfvars
# edit: domain (must match base), cluster sizing,
#       tf_state_bucket; leave the pinned chart versions alone
terraform init \
  -backend-config="bucket=<your-state-bucket>" \
  -backend-config="key=management/terraform.tfstate" \
  -backend-config="region=<region>" \
  -backend-config="dynamodb_table=<your-lock-table>"
terraform plan
terraform apply
```

This installs Argo CD, Crossplane, and the secrets operator on the new
cluster and applies the single bootstrap Application. From here on,
**everything is GitOps**: the bootstrap app syncs the repository's
`argocd/` tree — projects, composite resource definitions,
compositions, and every child Application — continuously from `main`.

Get credentials and watch it converge:

```bash
aws eks update-kubeconfig --name k8-platform-mgmt --region <region>
kubectl get applications -n argocd        # children appear and converge
```

The Argo CD UI comes up at `https://argocd.management.<domain>`
(admin credentials are exposed as Terraform outputs — read them with
`terraform output`, never from cluster secrets).

## 3. Pull the two deliberate gates

From here the procedure is identical to the supported path, because
these two syncs *are* the supported path's last two steps. They are the
part of this page with real evidence behind them: see
[Build the platform from nothing](build-the-platform-from-nothing.md),
steps 4 and 5, for the same commands with their waits and failure
modes. In short:

```bash
# 1. Create the platform services cluster:
argocd app sync platform-cluster-claim

#    Wait for the facts the second gate consumes, not for XR Ready:
for fact in oidcIssuer endpoint clusterCaData certificateArn; do
  kubectl wait --for=jsonpath="{.status.${fact}}" --timeout=1500s \
    xplatformclusters -A --all
done
kubectl wait --for=condition=Ready --timeout=1500s \
  nodegroups.eks.aws.m.upbound.io -A --all

# 2. Register the new spoke with the hub:
argocd app sync spoke-access

# 3. Only now wait for the composite resource itself:
kubectl wait --for=condition=Ready --timeout=2400s \
  xplatformclusters -A --all
```

Wait on the four published facts plus a `Ready` node group between the
two gates, because those are what the second gate consumes. Do not build
an expectation around when the composite itself becomes `Ready`.

!!! warning "Corrected 2026-09-10 (build #7)"
    This page previously said that waiting for the composite to become
    `Ready` before the second gate "deadlocks a fresh build", because the
    composed EKS identity-provider association supposedly had to wait for
    Keycloak. That is false. On build #7 the association reached
    `Ready=True reason=Available` at 01:13:50Z and the composite at
    01:14:17Z, while the second gate was not synced until 01:20:40Z — the
    association completed before Keycloak existed, and no retry loop
    occurred. On build #6 the composite went `Ready` after the second
    gate instead. Depend on neither ordering. Tracked as `kp-2al.23`.

    A real effect does exist, and it is a different one: an `ACTIVE`
    identity-provider association does not mean federated tokens are
    honoured yet. On build #7 federated `kubectl` was rejected about
    01:43Z and accepted about 01:54Z, with the brokered login and token
    claims already correct at the earlier time. Expect `Unauthorized` for
    a while after a build and retry rather than changing anything.

Once the spoke registers, the fact-driven ApplicationSets fan the
add-on stack out to it automatically — ingress, DNS, secrets, SSO
components, the demo app — in dependency order. No further commands.

## 4. Verify you are done

The platform's own definition of done, as observables:

```bash
# The behavioral gate — a real hostname, a valid public certificate:
curl -sSf https://hello.platform.<domain>

# The delivery surface — everything Synced/Healthy:
kubectl get applications -n argocd
```

Check the full sweep against
[What a finished platform contains](../reference/finished-platform.md)
— including the items that are expectedly *not* green today. Anything
absent from that inventory, or off-state without a listed reason, is a
defect to file.

---

*Tracking: bead `kp-2al.15` (demotion of this page), `OI-2026-07-06-4`
(no human-executed bring-up yet), ADR-0017 (bring-up is a user-facing
product surface).*
