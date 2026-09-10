---
status: contract
---

# Tear the platform down to nothing

Take a running platform back to an empty AWS account, in an order that
does not strand paid resources. This is the mirror of
[Build the platform from nothing](build-the-platform-from-nothing.md),
and on this platform it matters as much: the account rotates, and
rebuild-from-nothing is the product rather than a chore.

**Everything you need is on this page.** The order is not obvious and
three of its five stages exist because a shortcut failed on a real
teardown.

!!! danger "The two rules that cost the most when broken"
    **Never merge to `main` while a teardown is running.** Argo CD syncs
    a new target revision even with `selfHeal` off. On the build-#6
    teardown a merge mid-run made `bootstrap` re-apply the Application
    manifests from git with `selfHeal: true` restored, and a brand-new
    RDS instance began provisioning about five minutes after the
    database XR was deleted.

    **Never wait on an XR to confirm a deletion.** Deleting a composite
    and `kubectl wait --for=delete` on it both return in about two
    seconds while the EKS cluster, RDS instance, ACM certificate and IAM
    roles are all still live. The composite leaves the API immediately;
    the managed resources are what carry the deletion through to AWS.

## What this page assumes

- `kubectl` access to the **hub** (`k8-platform-mgmt`) and, until it is
  destroyed, the **spoke** (`k8-platform-services`). See
  [Get admin access and platform facts](admin-access.md).
- Credentials for the account, and permission to run
  `workflow_dispatch` on `.github/workflows/terraform-test.yml`.
- Nobody else is merging to `main` for the duration.

## The order, and why each stage exists

| # | Stage | Why it is here |
|---|---|---|
| 1 | Delete the LoadBalancer Services on **every** cluster | An orphaned NLB keeps the ACM certificate in use, and the certificate's managed resource then wedges |
| 2 | Remove Argo CD's finalizers and delete the Applications | Turning `selfHeal` off does not stop a new revision from re-creating what you deleted |
| 3 | Delete the XRs, then wait on the **managed resources** | The XR disappears instantly; AWS does not |
| 4 | `terraform destroy` management, then base | Reverse dependency order |
| 5 | Prove the account is empty | "It looked empty" is how resources get left running |

Then, only if you are preparing the account for a bring-up run,
[delete the state backend](#6-optional-delete-the-state-backend) — it
survives everything above.

---

## 1. Delete the LoadBalancer Services first

Each cluster's own controller removes its NLB when its `Service` goes
away. Do this **while both clusters still exist**, because a cluster
that is already gone cannot clean up after itself.

On the **spoke** (`k8-platform-services`):

```bash
kubectl -n ingress-nginx delete svc --all
```

On the **hub** (`k8-platform-mgmt`):

```bash
kubectl -n ingress-nginx delete svc --all
```

Watch them actually go, rather than assuming:

```bash
aws elbv2 describe-load-balancers \
  --query 'length(LoadBalancers)' --output text
```

*Measured on the build-#6 teardown:* the hub's NLB disappeared within
about **20 seconds** of its `Service` being deleted. The spoke's did
not, because the spoke cluster had already been destroyed — it had to be
removed through the AWS API by hand, and until it was, the ACM
certificate stayed **in use** and its `Certificate` managed resource
failed with `ResourceInUseException`, which stopped the teardown from
finishing. That is the whole reason this stage is first.

If you find yourself with an orphaned NLB and no cluster:

```bash
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].[LoadBalancerName,LoadBalancerArn]' --output text
aws elbv2 delete-load-balancer --load-balancer-arn <arn>
```

## 2. Stop Argo CD re-creating what you delete

Patching `selfHeal` off on the live Applications is **not enough**, and
this is not a subtlety — it was measured failing. What works is removing
Argo's finalizer from every Application and then deleting the
Applications, so nothing is left to reconcile.

On the **hub**:

```bash
# 1. Drop the resources-finalizer from every Application, including bootstrap.
for app in $(kubectl -n argocd get applications -o name); do
  kubectl -n argocd patch "$app" --type merge \
    -p '{"metadata":{"finalizers":null}}'
done

# 2. Delete them all.
kubectl -n argocd delete applications --all

# 3. Confirm nothing is left to sync.
kubectl -n argocd get applications
```

!!! warning "Delete `bootstrap` too"
    `bootstrap` is the app-of-apps and carries
    `resources-finalizer.argocd.argoproj.io`
    (`argocd/bootstrap.yaml`). Leaving it alive is what lets a merge to
    `main` re-apply every child Application with its original
    `syncPolicy`.

## 3. Delete the XRs, then wait on the managed resources

Delete the composites:

```bash
kubectl -n keycloak  delete xdatabase --all
kubectl -n keycloak  delete xplatformsecret --all
kubectl -n platform  delete xspokeaccess --all
kubectl -n platform  delete xplatformcluster --all
```

These return almost immediately. **Nothing is deprovisioned yet.**

!!! danger "`kubectl get managed` is useless here"
    It does **not** list namespaced Crossplane v2 managed resources, so
    during the build-#6 teardown it read reassuringly empty while four
    IAM roles and an EKS cluster were mid-delete. Enumerate the
    namespaced kinds instead.

Wait on the managed resources, across all namespaces:

```bash
for kind in \
  cluster.eks.aws.m.upbound.io \
  nodegroup.eks.aws.m.upbound.io \
  identityproviderconfig.eks.aws.m.upbound.io \
  accessentry.eks.aws.m.upbound.io \
  accesspolicyassociation.eks.aws.m.upbound.io \
  instance.rds.aws.m.upbound.io \
  certificate.acm.aws.m.upbound.io \
  certificatevalidation.acm.aws.m.upbound.io \
  record.route53.aws.m.upbound.io \
  securitygrouprule.ec2.aws.m.upbound.io \
  role.iam.aws.m.upbound.io \
  rolepolicyattachment.iam.aws.m.upbound.io \
  secret.secretsmanager.aws.m.upbound.io \
  secretversion.secretsmanager.aws.m.upbound.io
do
  printf '%-48s %s\n' "$kind" "$(kubectl get "$kind" -A --no-headers 2>/dev/null | wc -l)"
done
```

Re-run it until every count is `0`. **Budget: the spoke EKS cluster
alone takes about 10 to 15 minutes**, and it is the long pole.

If a managed resource stops making progress, trace it rather than
force-deleting it — a removed finalizer on a stuck MR orphans the AWS
resource behind it:

```bash
scripts/crossplane-trace.sh <kind>/<name> -n <namespace> --watch
```

## 4. `terraform destroy`, management then base

Both are `workflow_dispatch` runs of **Terraform Test**
(`.github/workflows/terraform-test.yml`), the same workflow the bring-up
uses. Run them **in this order** and wait for each to finish:

| Order | `phase` | `action` | Budget |
|---|---|---|---|
| 1 | `management` | `destroy` | about **13 minutes** |
| 2 | `base` | `destroy` | under **2 minutes** |

Reverse dependency order is not optional: the management module's
cluster sits in the base module's VPC.

!!! warning "Never push while a live-verify dispatch is in flight"
    The live-evidence gate keys on the pushed head SHA, so a commit
    landed mid-run strands the evidence the run produced and costs a
    re-run. Batch follow-ups until the run is done.

## 5. Prove the account is empty

Do not skip this and do not read it casually — an orphaned NLB or RDS
instance bills quietly.

```bash
echo "EKS clusters:    $(aws eks list-clusters --query 'length(clusters)' --output text)"
echo "Load balancers:  $(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text)"
echo "RDS instances:   $(aws rds describe-db-instances --query 'length(DBInstances)' --output text)"
echo "k8-platform IAM roles:"
aws iam list-roles --query "Roles[?starts_with(RoleName, 'k8-platform-')].RoleName" --output text
```

Expected: `0`, `0`, `0`, and no role names.

Also worth a glance, because they are the two that have surprised a
teardown before:

```bash
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running \
  --query 'length(Reservations[].Instances[])' --output text
aws acm list-certificates --query 'length(CertificateSummaryList)' --output text
```

!!! note "Secrets Manager entries survive, by design"
    ASM secrets written by External Secrets' `PushSecret` outlive a
    teardown: the push role's policy deliberately carries no
    `secretsmanager:DeleteSecret`
    (`terraform/management/irsa.tf`). Crossplane-composed ASM secrets
    *are* removed with their managed resources
    (`managementPolicies: [Observe, Create, Update, Delete]` in
    `crossplane/compositions/platform-secret.yaml`). Build #7 rebuilt
    successfully over the survivors, so this is a note, not a blocker.

## 6. Optional: delete the state backend

**The Terraform state bucket and the DynamoDB lock table survive a
teardown.** They are bootstrapped outside Terraform, so a torn-down
account is **not** equivalent to a fresh one.

This is not academic. On build #7 the leftover backend made the
bring-up page's credential probe come out **green** where the page
predicts red, because the state-backend checks passed — a contradiction
that costs the reader their trust in the page before they have run
anything.

So: if the next thing to happen on this account is a bring-up run
executed as written, remove them.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="k8-platform-tfstate-${ACCOUNT_ID}"
TABLE="k8-platform-tfstate-lock"

# The bucket is versioned; a plain `rb` will refuse while versions remain.
aws s3api delete-objects --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)" \
  2>/dev/null || true
aws s3api delete-objects --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)" \
  2>/dev/null || true
aws s3 rb "s3://${BUCKET}"

aws dynamodb delete-table --table-name "$TABLE"
```

Confirm they are gone — this is exactly what the bring-up probe checks:

```bash
aws s3api head-bucket --bucket "$BUCKET"       # expect an error
aws dynamodb describe-table --table-name "$TABLE"  # expect an error
```

If you keep them instead, that is fine — but tell whoever builds next
that the probe's state-backend checks will pass, so a green probe is not
evidence of a stale account.

## Budgets, end to end

| Stage | Measured |
|---|---|
| Hub NLB removal after deleting its `Service` | about 20 s |
| Spoke EKS cluster delete | about 10–15 min |
| `management` `destroy` | about 13 min |
| `base` `destroy` | under 2 min |

Stages 1–3 are hands-on; stage 4 is two workflow runs you wait on.

## What is attested, and what is not

Stages 1 to 3 and the two `terraform destroy` runs are reconstructed
from the **build-#6 teardown on 2026-09-09/10**, which is where every
measured figure and every failure described above comes from
(management destroy run `34419405234`, base destroy run `34420560366`).

This page has **not been executed end to end as written** — it is the
ordered procedure the teardown *arrived at* after going wrong, not a
transcript of a run that followed it. Per ADR-0018 (documentation is
verified by fenced execution) it stays `contract` until a reader
executing only this page completes it, and every gap, guess and
mismatch they report is filed as a defect. Tracked as `kp-2al.30`.

The stage-1 and stage-3 command forms in particular are the shapes the
teardown used; the exact `for`-loops here were assembled for this page
and have not themselves been run against a live platform.

## Related

- [Build the platform from nothing](build-the-platform-from-nothing.md)
  — the mirror of this page.
- [What a finished platform contains](../reference/finished-platform.md)
  — the inventory this teardown empties.
- [Get admin access and platform facts](admin-access.md) — how to reach
  both clusters.
