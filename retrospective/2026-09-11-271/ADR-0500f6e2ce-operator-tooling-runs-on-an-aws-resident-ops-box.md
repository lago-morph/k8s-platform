# ADR: Operator tooling runs on an AWS-resident ops box, never on the operator's machine

- **ID**: ADR-0500f6e2ce
- **Status**: Draft (not yet adopted to `docs/decisions/`)
- **Date**: 2026-09-11
- **Source retrospective**: ../2026-09-11-271.md
- **PRs covered**: #270, #271

## Context

The documented bring-up (`docs/site/how-to/build-the-platform-from-nothing.md`)
spanned the GitHub Actions UI, a terminal with a kubeconfig, and a seven-row
verification sweep the operator had to interpret by hand. After reading it end to
end the owner's verdict was that the manual steps are "unreasonably complex" and
error-prone, and asked for terraform plus scripts that execute each step and report
red or green. A later correction narrowed this precisely: "it is ok to have me do
manual github things. I just don't want all the complex interpretations." Clicking
two workflow buttons is acceptable; interpreting live cluster state against a prose
checklist is not.

The constraint that actually shaped the design came next, and it is a security
constraint, not a convenience one: "my laptop is set up with secrets from work, not
for this project. I want to keep them completely separate." Docker was explicitly
raised by the owner as an option and rejected on analysis — a container isolates
this project's credentials from the work ones, but the credentials still have to
*exist* on the laptop, which is the actual worry. The owner also established that
secrets can be updated on GitHub but cannot be injected into a running sandbox
session, so the sandbox is not a durable home for them either.

## Decision

The bring-up is driven from an EC2 ops box that holds an IAM instance profile and is
reached through SSM Session Manager in the AWS console, so this project's
credentials are issued by AWS to the instance and never exist as a file on any
machine the operator touches.

Concretely: `terraform/opsbox` is a standalone module applied by workflow dispatch
(`.github/workflows/opsbox.yml`), so nothing runs from a laptop and the box is
reproducible from committed source. It lives in the **default VPC**, not the
platform's, because it must predate `terraform/base`, be able to watch the base
build happen, and survive the teardown that removes the platform VPC. Access is
Session Manager only — the security group opens nothing inbound, there is no SSH
key, no access key, and no local kubeconfig. The box grants itself EKS access
entries for each cluster as that cluster appears, because the clusters do not exist
when the module is applied.

## Alternatives considered

- **A Docker container on the operator's laptop.** Raised by the owner. Rejected
  because it solves isolation between this project's credentials and work
  credentials, but not the stated worry: the credentials would still be present on
  the laptop's filesystem, one `docker cp` or mounted volume away from the work
  environment.
- **A laptop CLI with narrowly-scoped AWS keys.** Rejected for the same reason,
  plus it needs a kubeconfig for two clusters and a GitHub token. The owner's
  intent for step 6 is exactly this shape — a `kubectl`-like CLI driven from a
  laptop with segregated credentials — but they explicitly deferred it: "I don't
  want to implement that now."
- **Keep the manual page and accept the interpretation cost.** Rejected by the
  owner's own reading of it; six builds had been executed against that page and the
  fenced teardown validation found fifteen defects in its sibling runbook, which is
  the empirical case that prose checklists are not a reliable operator interface.
- **Put the ops box in the platform's VPC.** Rejected on lifecycle grounds: it
  would be destroyed by every teardown and would be unable to observe the build
  that creates it — the two things it exists to do.

## Consequences

Easier: no credential ever lands on an operator machine, so there is no leak
surface to reason about and no cleanup after a session. The box is reproducible
from source, so "what did the operator's environment look like" is answerable from
git. Because it lives in the default VPC, one box can watch a full build-and-teardown
cycle.

Harder, and knowingly accepted: the default VPC's subnets are public, so the box
takes a public IP to reach GitHub and the package mirrors without paying for a NAT
gateway — acceptable only because nothing listens inbound and the security group
opens nothing. The box is a second thing to create and destroy per account, and its
`apply` bootstraps the terraform state backend as a side effect, which changes what
the credential probe reports on a fresh account (red state-backend checks flip
green). The module is also exposed to per-AZ instance-type availability in a way a
laptop is not — the first apply failed because the default VPC has a subnet in every
AZ including `us-east-1e`, where `t3.small` is not offered at all.

## References

- [`../2026-09-11-271.md`](../2026-09-11-271.md) — the source retrospective.
- [`./ADR-7ccc085c26-bring-up-status-is-derived-from-the-world.md`](./ADR-7ccc085c26-bring-up-status-is-derived-from-the-world.md) — the companion decision about what the tooling trusts as truth.
- `terraform/opsbox/main.tf` — the module, whose header comments carry this rationale.
- `docs/site/how-to/admin-access.md` §4 — the directory-account admin action the box is permitted to perform.
- [`../../docs/decisions/0017-bring-up-is-a-user-facing-product-surface.md`](../../docs/decisions/0017-bring-up-is-a-user-facing-product-surface.md) (ADR-e45d9382dc) — the accepted decision this one serves: bring-up is a product surface, so its operator interface is a product decision rather than an internal convenience.
- Bead `kp-2al.34` — the scope and the owner direction verbatim.
- PRs the decision was made in: #270, #271.
