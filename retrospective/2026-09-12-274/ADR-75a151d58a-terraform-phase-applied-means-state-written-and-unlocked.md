# ADR: A Terraform phase counts as applied only when its remote state is written and its lock is free

- **ID**: ADR-75a151d58a
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-09-12
- **Source retrospective**: ../2026-09-12-274.md
- **PRs covered**: #273

## Context

On build #9 the driver's `check_base` reported `GREEN base applied` 46
seconds after it started. The wildcard certificate was ISSUED at 04:36:01Z
and the Cognito user pool existed at 04:36:02Z, while base's `terraform
apply` kept creating the VPC until it wrote state at 04:38:33Z. The check
asserted exactly the two facts the workflow's own `[base] e2e-verify` step
asserts, and both were true; the phase was nevertheless not applied. A
human following the driver's next `ACTION NEEDED` would have dispatched
management against base state that did not yet exist, and management reads
that state. The same shape applies to management: the hub cluster and node
group are ACTIVE and the `bootstrap` Application exists minutes before the
apply finishes its remaining resources.

The session then measured what "the apply has finished" looks like in the
world. The S3 backend writes the state object at the end (with periodic
persistence during long applies) and holds a DynamoDB item whose `LockID`
is `<bucket>/<key>` for exactly the duration of the apply; a `<key>-md5`
digest item persists afterwards and is not a lock. Probed live: base read
settled and management read held while its apply ran.

## Decision

Every consumer that asks whether base or management is applied requires the phase's state object to exist in the state bucket and its DynamoDB lock item to be absent, in addition to the resources the phase creates.

`scripts/opsbox/lib.sh` implements it as `state_settled <phase>`: the
object `k8-platform/<phase>/terraform.tfstate` must be listed in
`k8-platform-tfstate-<account>`, and `get-item` on
`k8-platform-tfstate-lock` for `LockID=<bucket>/<key>` must return no item.
An unreadable lock (IAM denial, API error) reads as not settled, never as
free. `check_base` and `check_management` call it first. The bring-up
page's stage table states the condition, and the ops-box role carries
`dynamodb:GetItem` for the read.

## Alternatives considered

- **Assert on the resources the phase creates, as before.** Rejected by
  measurement: they exist early. Adding "later" resources (a NAT gateway, a
  route) only moves the race; Terraform's graph order is not a contract.
- **Ask GitHub whether the run went green.** Rejected: the driver's design
  rule (ADR-7ccc085c26) forbids trusting a run's colour, and the box holds no
  GitHub token by design.
- **Wait a fixed margin after the facts appear.** Rejected: base took
  3m14s on build #9 and 3m21s on #8, but a slow apply or a re-apply that
  changes little makes any margin either wasteful or wrong.
- **Check only the state object's existence.** Rejected: Terraform persists
  state periodically during an apply, so the object can exist mid-apply. The
  lock is the only signal that means "no apply is in flight".

## Consequences

Easier: "applied" has one meaning shared by the driver, the status screen
and the page, and it is a read against the account rather than an
inference. The unit suite pins the meaning (state absent, lock held, lock
unreadable all reject).

Harder: a running `plan` or a held stale lock also reads as not settled,
so the driver waits through them; that is the correct direction. The
box's role needs one more read permission. Any future phase or tool that
wants to say "applied" must read the backend the same way.

Accepted trade-off: the driver depends on the backend's naming
convention, which `tests/unit/test_opsbox_bringup.sh` already pins between
the two workflows.

## References

- [`../2026-09-12-274.md`](../2026-09-12-274.md) — the source retrospective.
- [`../2026-09-11-271/ADR-7ccc085c26-bring-up-status-is-derived-from-the-world.md`](../2026-09-11-271/ADR-7ccc085c26-bring-up-status-is-derived-from-the-world.md) — the rule this refines.
- `scripts/opsbox/lib.sh` (`state_settled`), `tests/unit/test_opsbox_bringup.sh`, commits `a8553d6` and `b9e84bf`.
- PRs the decision was made in: #273.
