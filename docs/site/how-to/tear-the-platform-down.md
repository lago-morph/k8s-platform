---
status: contract
---

# Tear the platform down to nothing

Take a running platform back to an empty AWS account, in an order that
does not strand paid resources. This is the mirror of
[Build the platform from nothing](build-the-platform-from-nothing.md),
and on this platform it matters as much: the account rotates, and
rebuild-from-nothing is the product rather than a chore.

**Everything you need is on this page.** The order is not obvious, and
every stage below exists because a shortcut failed on a real teardown.

!!! danger "The three rules that cost the most when broken"
    **Stop Argo CD before you delete anything it manages.** Argo does not
    only re-sync — its `ApplicationSet`s *regenerate* Applications about a
    second after you delete them. Deleting a LoadBalancer `Service` while
    Argo is still live gets you a **new** load balancer, not a deleted
    one.

    **Never merge to `main` while a teardown is running.** Argo syncs a
    new target revision even with `selfHeal` off. On the build-#6
    teardown a merge mid-run made `bootstrap` re-apply the Application
    manifests from git with `selfHeal: true` restored, and a brand-new
    RDS instance began provisioning about five minutes after the database
    XR was deleted.

    **Never wait on an XR to confirm a deletion.** Deleting a composite
    and `kubectl wait --for=delete` on it both return in about two
    seconds while the EKS cluster, RDS instance, ACM certificate and IAM
    roles are all still live. The composite leaves the API immediately;
    the managed resources are what carry the deletion through to AWS.

## What this page assumes

- `kubectl` access to the **hub** (`k8-platform-mgmt`) and the **spoke**
  (`k8-platform-services`), with permission to delete. See
  [Get admin access and platform facts](admin-access.md).
- Credentials for the account, and permission to run
  `workflow_dispatch` on `.github/workflows/terraform-test.yml`.
- Nobody else is merging to `main` for the duration.
- You are at the root of a checkout of this repository (one command
  below is a relative path).

## The order, and why each stage exists

| # | Stage | Why it is here |
|---|---|---|
| 1 | Stop Argo CD: delete the **ApplicationSets** first, then the Applications | ApplicationSets regenerate deleted Applications in about a second; nothing else you delete stays deleted until this is done |
| 2 | Delete the LoadBalancer Services on **every** cluster | An orphaned NLB keeps the ACM certificate in use, and the certificate's managed resource then wedges |
| 3 | Delete the spoke's PersistentVolumeClaims | Dynamically-provisioned EBS volumes outlive the cluster that could have reclaimed them, and bill quietly |
| 4 | Delete the XRs, then wait on the **managed resources** | The XR disappears instantly; AWS does not |
| 5 | `terraform destroy` management, then base | Reverse dependency order |
| 6 | Prove the account is empty | "It looked empty" is how resources get left running |

Stages 2 and 3 must happen **while both clusters still exist** — a
cluster that is already gone cannot clean up after itself — and after
stage 1, or Argo puts back what you remove.

Then, only if you are preparing the account for a bring-up run,
[delete the state backend](#7-optional-delete-the-state-backend).

---

## 1. Stop Argo CD re-creating what you delete

Patching `selfHeal` off on the live Applications is **not enough**, and
neither is deleting the Applications. Both were measured failing.

Delete the **ApplicationSets first**. Deleting an ApplicationSet cascades
to the Applications it generated; deleting those Applications on their
own just makes the ApplicationSet build them again.

On the **hub**:

```bash
# 1. The generators. This cascades to the Applications they own.
kubectl -n argocd delete applicationsets --all

# 2. Drop the resources-finalizer from whatever Applications remain,
#    including bootstrap, so their deletion does not block.
for app in $(kubectl -n argocd get applications -o name); do
  kubectl -n argocd patch "$app" --type merge \
    -p '{"metadata":{"finalizers":null}}'
done

# 3. Delete the rest.
kubectl -n argocd delete applications --all

# 4. Confirm.
kubectl -n argocd get applications,applicationsets -n argocd
```

**Expect step 4 to print `No resources found in argocd namespace.`** If
it prints a table instead — even one whose rows all say `Synced` and
`Healthy` — the teardown has not started. A fenced execution of an
earlier version of this page deleted all 17 Applications and had nine of
them regenerated one second later, and the reassuring `Synced`/`Healthy`
table is exactly what that looks like.

!!! warning "Removing the finalizer means Argo will not clean up for you"
    `resources-finalizer.argocd.argoproj.io` is what makes Argo delete an
    Application's *deployed resources* when the Application goes. Strip
    it and you get the opposite: the Application disappears and its
    workloads keep running, unmanaged. That is what we want here — stages
    2 to 4 remove those workloads deliberately and in order — but it is
    why the later stages cannot be skipped.

    In the measured run only `bootstrap` reported `patched`; every other
    Application reported `patched (no change)`, because they carried no
    finalizer. That is normal, not a sign the patch failed.

## 2. Delete the LoadBalancer Services

Each cluster's own controller removes its NLB when its `Service` goes
away, so do this **while both clusters still exist**.

Delete the LoadBalancer Services specifically, rather than every Service
in the namespace — `delete svc --all` also removes the ingress
controller's admission `Service`, which matters if you ever run this
against a cluster you intend to keep:

```bash
# On the spoke (k8-platform-services), then repeat on the hub
# (k8-platform-mgmt):
kubectl -n ingress-nginx delete svc \
  $(kubectl -n ingress-nginx get svc \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{" "}{end}')
```

Verify by **name**, not by count:

```bash
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].[LoadBalancerName,State.Code]' --output text
```

A bare count cannot tell "the second one is still draining" from "a new
one has just been created" — both read as `1`. Compare the names against
what was there before you started.

*Measured:* the hub's NLB disappeared about **19 seconds** after its
`Service` was deleted. On the build-#6 teardown the spoke's did not,
because the spoke cluster had already been destroyed — it had to be
removed through the AWS API by hand, and until it was, the ACM
certificate stayed **in use** and its `Certificate` managed resource
failed with `ResourceInUseException`, which stopped the teardown from
finishing.

Only the spoke runs its ingress from an Application; the hub's
`ingress-nginx` is installed by Terraform. So if you do this before
stage 1 by mistake, the spoke's Service comes back and the hub's does
not.

If you end up with an orphaned NLB and no cluster:

```bash
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].[LoadBalancerName,LoadBalancerArn]' --output text
aws elbv2 delete-load-balancer --load-balancer-arn <arn>
```

## 3. Delete the spoke's PersistentVolumeClaims

The spoke's observability stack uses StatefulSets with dynamically
provisioned `gp3` volumes. When the cluster goes, its EBS CSI controller
goes with it, and **nothing will ever reclaim those volumes** — they sit
`available` and bill. This is the same class of problem as the orphaned
NLB in stage 2, and it is easy to miss because no cluster object is left
pointing at them.

Stage 1 left the workloads running but unmanaged, so remove them and
their claims together. On the **spoke**:

```bash
kubectl -n monitoring delete statefulsets --all
kubectl -n monitoring delete pvc --all
kubectl get pvc -A          # expect: No resources found
```

With the default `Delete` reclaim policy on the `gp3` StorageClass, the
CSI driver deletes the backing EBS volume as each claim goes.

!!! warning "This stage is not attested"
    The teardown that produced this page skipped straight from stage 2 to
    stage 4, which is how the leftover volumes were discovered. Stage 6
    checks for them regardless, and tells you how to remove them by hand,
    so a reader who finds this stage does not work is not left with a
    bill — but the commands above have not themselves been executed.

## 4. Delete the XRs, then wait on the managed resources

Delete the composites:

```bash
kubectl -n keycloak  delete xdatabase --all
kubectl -n keycloak  delete xplatformsecret --all
kubectl -n platform  delete xspokeaccess --all
kubectl -n platform  delete xplatformcluster --all
```

These return almost immediately — **4 seconds** for all five in the
measured run, while the EKS cluster lived another fourteen minutes.
**Nothing is deprovisioned yet.**

!!! danger "`kubectl get managed` is useless here"
    It does **not** list namespaced Crossplane v2 managed resources, so
    during the build-#6 teardown it read reassuringly empty while four
    IAM roles and an EKS cluster were mid-delete. Enumerate the
    namespaced kinds instead.

Wait on the managed resources, across all namespaces. Re-run this every
minute or so until every count is `0`:

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

*Measured:* **14m16s** to all-zero. RDS was gone within three minutes;
everything except the EKS cluster, its node group and one IAM role was
gone by seven minutes; the last three cleared between eight and fourteen.
The spoke EKS cluster is the long pole.

If a managed resource stops making progress, trace it rather than
force-deleting it — a removed finalizer on a stuck MR orphans the AWS
resource behind it. From the root of a checkout of this repository:

```bash
scripts/crossplane-trace.sh <kind>/<name> -n <namespace> --watch
```

## 5. `terraform destroy`, management then base

!!! warning "After this stage you have no cluster access"
    The management destroy takes the hub with it. Anything you still want
    to read from either cluster must be read **before** you start.

Both are `workflow_dispatch` runs of **Terraform Test**
(`.github/workflows/terraform-test.yml`). Its two inputs are named
`phase` and `action`. Run them **in this order** and wait for each to
finish:

| Order | `phase` | `action` | Budget | Measured |
|---|---|---|---|---|
| 1 | `management` | `destroy` | about 13 min | 13m43s |
| 2 | `base` | `destroy` | under 2 min | 1m36s |

Reverse dependency order is not optional: the management module's
cluster sits in the base module's VPC.

!!! warning "Never push while a live-verify dispatch is in flight"
    The live-evidence gate keys on the pushed head SHA, so a commit
    landed mid-run strands the evidence the run produced and costs a
    re-run. Batch follow-ups until the run is done.

## 6. Prove the account is empty

Do not skip this and do not read it casually — an orphaned load
balancer, RDS instance or EBS volume bills quietly.

```bash
echo "EKS clusters:    $(aws eks list-clusters --query 'length(clusters)' --output text)"
echo "Load balancers:  $(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text)"
echo "RDS instances:   $(aws rds describe-db-instances --query 'length(DBInstances)' --output text)"
echo "EBS volumes:     $(aws ec2 describe-volumes --query 'length(Volumes)' --output text)"
echo "Running EC2:     $(aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query 'length(Reservations[].Instances[])' --output text)"
echo "ACM certs:       $(aws acm list-certificates --query 'length(CertificateSummaryList)' --output text)"
echo "k8-platform IAM roles:"
aws iam list-roles --query "Roles[?starts_with(RoleName, 'k8-platform-')].RoleName" --output text
```

Expected: `0` for every count, and no role names.

**If the EBS count is not zero**, stage 3 did not happen or did not work.
The volumes are safe to remove once the cluster is gone — nothing else
references them:

```bash
aws ec2 describe-volumes --output text \
  --query 'Volumes[?State==`available`].[VolumeId,Size,Tags[?Key==`kubernetes.io/created-for/pvc/name`].Value|[0]]'
aws ec2 delete-volume --volume-id <vol-id>     # repeat per volume
```

*Measured on this platform:* three `available` `gp3` volumes totalling
22 GiB survived a teardown that otherwise passed every other check —
the spoke's Loki, Prometheus and Alertmanager claims.

!!! note "One Secrets Manager entry survives, by design"
    `k8-platform/keycloak-db` outlives a teardown: it is written by
    External Secrets' `PushSecret`, and the push role's policy
    deliberately carries no `secretsmanager:DeleteSecret`
    (`terraform/management/irsa.tf`). The Crossplane-composed ASM
    secrets *are* removed with their managed resources. Build #7 rebuilt
    successfully over the survivor, so this is a note, not a blocker.

!!! note "The Route53 hosted zone is not yours to delete"
    The account's public hosted zone is **pre-existing** — it comes with
    the account, and the build discovers it rather than creating it. It
    survives a teardown and it should: deleting it would break the next
    bring-up, which looks it up in its first minute. Leave it alone.

## 7. Optional: delete the state backend

**The Terraform state bucket and the DynamoDB lock table survive a
teardown.** They are bootstrapped outside Terraform, so a torn-down
account is **not** equivalent to a fresh one.

This is not academic. On build #7 the leftover backend made the bring-up
page's credential probe come out **green** where the page predicts red,
because the state-backend checks passed — a contradiction that costs the
reader their trust in the page before they have run anything.

**Decide by what happens to this account next**, and if you do not know,
leave them:

| Next thing on this account | Do |
|---|---|
| Somebody executes the bring-up page as written | **Delete them.** Otherwise step 1's probe contradicts the page |
| Another build by someone who knows the account is used | Keep them; the build reuses the backend |
| You do not know | **Keep them**, and tell whoever builds next that the probe's state-backend checks will pass |

Deleting them is irreversible, and it discards the Terraform state for a
platform you have just destroyed.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="k8-platform-tfstate-${ACCOUNT_ID}"
TABLE="k8-platform-tfstate-lock"

# The bucket is versioned; a plain `rb` refuses while versions remain.
# The second call finds nothing unless objects were deleted earlier —
# an empty result there is normal.
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
aws s3api head-bucket --bucket "$BUCKET"           # expect an error
aws dynamodb describe-table --table-name "$TABLE"  # expect an error
```

## Budgets, end to end

| Stage | Measured |
|---|---|
| Stage 1, Argo stopped (with the ApplicationSet delete) | about 25 s |
| Hub NLB removal after deleting its `Service` | about 19 s |
| Stage 4, XR deletes returning | 4 s |
| Stage 4, managed resources to all-zero | 14m16s |
| `management` `destroy` | 13m43s |
| `base` `destroy` | 1m36s |
| **End to end** | about **1 hour** |

## What is attested, and what is not

The ordering, the budgets and the failure modes come from two runs: the
**build-#6 teardown** (2026-09-09/10), which is where the NLB/ACM
deadlock and the Argo re-creation were first measured, and a **fenced
execution of this page against build #8** (2026-09-10, runs
`34516300481` and `34517977976`), which ran it start to finish on a live
account and produced the corrections now folded in — the stage ordering,
the ApplicationSets, the leftover EBS volumes, and every expected-output
line.

Still not attested:

- **Stage 3 has never been executed.** See its own warning.
- **No person has run this page.** The fenced execution was an agent, and
  ADR-0018 reserves `stable` for a human run. The marker stays `contract`.
- The fenced reader's isolation was imperfect: a catalogue of
  repository-specific skill descriptions was injected into its context
  automatically, which leaks some vocabulary about the platform. It
  reported this itself, and every correction above traces to output it
  observed on the live account rather than to that catalogue.

Tracked as `kp-2al.30`; the defect record it closes is `kp-2al.21`.

## Related

- [Build the platform from nothing](build-the-platform-from-nothing.md)
  — the mirror of this page.
- [What a finished platform contains](../reference/finished-platform.md)
  — the inventory this teardown empties.
- [Get admin access and platform facts](admin-access.md) — how to reach
  both clusters.
