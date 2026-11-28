# k8-platform

A production-like Kubernetes platform on AWS, built as a learning reference
and the companion to a planned blog series. It covers what has to exist
before an application can run in an enterprise setting: a GitOps control
plane, automatic DNS and TLS, single sign-on for cluster access, secrets that
never live in Git, and a management plane that survives a bad rollout.

The platform is **intentionally ephemeral**: it is built from nothing on a
fresh AWS account, verified, and torn down. Rebuilding from scratch is the
product, not a chore.

## Status

**Working and tested end to end.** The latest clean build (#11, 2026-11-28)
was built from `main` on a brand-new AWS account with no manual fixes, and
the platform's own behavioural suite (Live verify) passed every check:
`pass=30 skip=0 fail=0`. Run IDs and the full record of every build are in
[`SUBSTRATE-READINESS.md`](SUBSTRATE-READINESS.md).

| | Today |
|---|---|
| **Management cluster** (the hub) | Built and verified |
| **Platform services cluster** (the first spoke) | Built and verified |
| **Tenant / workload clusters** | Defined in the repository but not built; planned for a future release |
| Kubernetes | 1.37 on every cluster |
| Nodes | 2× `m5.large` per cluster, Amazon Linux 2023 |

What comes next is in [`ai/roadmap.md`](ai/roadmap.md): step 3 (feature
complete) is done; step 3.1 brings every component to its current release and
pins every dependency; step 3.2 adds single sign-on to Argo CD and Grafana.

## Architecture

```
GitHub repository  ──(GitOps)──►  Management cluster  (EKS, built by Terraform)
                                    Argo CD · Crossplane · External Secrets
                                    ingress-nginx · ExternalDNS
                                         │ provisions and deploys to
                                         ▼
                                  Platform services cluster  (EKS, built by Crossplane)
                                    ingress-nginx · ExternalDNS · External Secrets
                                    Keycloak · Prometheus · Grafana · Loki
                                    EBS CSI storage · the "hello" demo app
                                         ·
                                         ·  future release
                                         ▼
                                  Tenant / workload clusters  (EKS, built by Crossplane)
```

- **The hub is the only part Terraform builds.** Everything else is created
  by Crossplane and deployed by Argo CD from this repository, so a bad
  platform change can never take down the thing that would repair it.
- **TLS** is AWS Certificate Manager, issued and DNS-validated through
  Crossplane and terminated at each cluster's load balancer, which accepts
  TLS 1.2 and 1.3 only.
- **Identity:** Keycloak on the platform cluster federates to an Amazon
  Cognito user pool, and EKS trusts Keycloak, so `kubectl` users sign in with
  a directory account. Argo CD and Grafana SSO are planned for step 3.2.
- **Secrets** live in AWS Secrets Manager and reach clusters through External
  Secrets; IAM roles for service accounts everywhere, no static credentials
  in any manifest.

Concepts in more depth: [Platform topology](docs/site/explanation/platform-topology.md).
Design rationale: [`ai/DESIGN.md`](ai/DESIGN.md) and the decision records in
[`decisions/`](decisions/) and [`docs/decisions/`](docs/decisions/).

## Building it

Everything happens from a browser: GitHub Actions and the AWS console.
Nothing needs to be installed on your machine. The full, step-by-step guide
is **[Build the platform from nothing](docs/site/how-to/build-the-platform-from-nothing.md)**.
In short:

1. **Ops box → apply** creates a small EC2 instance that drives the build.
2. Open a Session Manager shell to it from the AWS console and run
   `k8p-bringup.sh`.
3. When it asks, run **Terraform Test** with `phase=base`, then with
   `phase=management`.
4. When it prints `BRING-UP COMPLETE`, run **Live verify** for the
   platform's verdict.

**Prerequisites:** an AWS account with a public Route53 hosted zone, its
credentials in this repository's GitHub Actions secrets
(`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`), and the repository variable
`AWS_REGION`. A full build takes about an hour.

When you are done: [Tear the platform down](docs/site/how-to/tear-the-platform-down.md).

## Using it

- [Admin access](docs/site/how-to/admin-access.md): cluster access over the
  public endpoints (`scripts/k8p-kubeconfig.sh`), the Argo CD admin password
  (`scripts/k8p-argocd-password.sh`), and directory accounts
  (`scripts/k8p-cognito-user.sh`).
- [Check health and find URLs](docs/site/how-to/check-health-and-find-url.md),
  including where to find logs.
- [Deploy an application](docs/site/how-to/deploy-an-application.md) and the
  other how-to guides.

The documentation site is published at
**<https://lago-morph.github.io/k8s-platform/>**.

## Repository layout

```
terraform/base/        shared AWS foundations: VPC, certificate, Cognito, state
terraform/management/  the management (hub) cluster and everything installed on it
terraform/opsbox/      the ops box that drives a build
crossplane/            XRDs and Compositions (platform cluster, secrets, databases, spoke access)
clusters/              the composite resources that define each spoke cluster
argocd/                Argo CD Applications, ApplicationSets and Projects
platform-services/     Helm values for everything on the platform cluster
scripts/               bring-up driver, admin scripts, diagnostics
tests/                 unit, chainsaw (Crossplane on kind) and live behavioural suites
docs/site/             the documentation site (how-tos, reference, explanation)
ai/                    roadmap, handoff, design, and agent working notes
```

## Contributing (humans and agents)

Agents start with [`AGENTS.md`](AGENTS.md). The working rule for everyone:
**done means proven on a clean build** — a change counts only when a build
from committed code, with no manual steps, shows it working.
