# ADR: Permission narrowings are validated on the delete path before they are called done

- **ID**: ADR-d08b24eb51
- **Status**: Draft (not yet adopted to docs/decisions/)
- **Date**: 2026-09-10
- **Source retrospective**: ../2026-09-10-267.md
- **PRs covered**: #267

## Context

The platform's Crossplane IRSA policy had been narrowed deliberately and validated
deliberately. The source comment on the `IAMRoles` statement records that the
narrowing was "validated on the spoke XSpokeAccess CREATE path before this
narrowing is called done", paired with a live deny-simulation check and a source
regression guard. Six consecutive clean builds passed over it.

On 2026-09-10 the first teardown the project had ever performed wedged. Every
composed IAM role refused to delete:

```
async delete failed: failed to delete the resource: deleting IAM Role
(k8-platform-<cluster>-ebs-csi): reading IAM Instance Profiles for Role:
ListInstanceProfilesForRole ... AccessDenied
```

The AWS provider reads a role's instance profiles before deleting it. The policy
granted `iam:DeleteRole`, `iam:ListRolePolicies` and `iam:ListAttachedRolePolicies`
but not `iam:ListInstanceProfilesForRole`, so all five spoke roles leaked and were
left to collide with the next build's creates. Three further defects surfaced in
the same teardown, all on paths no build exercises: orphaned load balancers that
hold an ACM certificate hostage, a composite delete that returns in two seconds
while the cluster is still live, and a self-heal suppression that a merge silently
undid.

The common shape is that validation had been scoped to the direction the project
habitually moves. "Validated on the CREATE path" is a true statement that was
being read as "validated". The create path never calls the missing action, so no
amount of create-side testing could have found it, and the cost was not abstract:
the teardown stalled until the policy was fixed and re-applied live.

## Decision

A permission narrowing is not done when the create path passes; it is done when
the delete path has also been exercised, or when a source assertion pins the
delete-path actions the provider requires.

The assertion is the cheap half and is mandatory, because it is the only layer
that can catch this class without a teardown: for each narrowed statement, a unit
test asserts the presence of the delete-path actions the provider calls, with a
comment naming the provider behaviour that requires each one. The exercise is the
authoritative half: a narrowing that has never had its resources deleted under it
is recorded as unexercised on the delete path rather than as validated.

## Alternatives considered

**Grant the provider broader permissions and stop narrowing.** Rejected. The
narrowing exists because the project treats an over-broad Crossplane identity as a
security defect, and there is an existing live check that simulates denied
cross-account creates to prove the narrowing fires. Widening to avoid a testing
gap trades a real security property for a testing convenience.

**Rely on the live deny-simulation check already in place.** It did not and cannot
catch this: it simulates create actions against the rendered policy. Extending it
to simulate every delete-path action would require knowing which actions the
provider calls during delete, which is exactly the knowledge that was missing —
and a simulation of a guessed action list proves only that the guess is internally
consistent.

**Wait for a teardown to find these naturally.** This is what happened, and the
finding was genuinely valuable, but it is not a policy. Teardowns here are rare
and occur under account-expiry pressure, which is the worst moment to discover
that the identity cannot delete. The same teardown also nearly orphaned paid
resources.

**Make the delete path part of every build.** Appealing — a build that ends by
destroying what it made would exercise both directions every time — but it doubles
the wall-clock cost of the project's slowest operation and consumes the account
window that other work needs. Rejected for now; the cheap assertion plus an
explicit unexercised status gets most of the protection.

## Consequences

**Easier.** The failure class becomes catchable without a cluster: the fix for the
IAM gap shipped with a source assertion verified red first (27 passed, 1 failed
against the unfixed policy) and green after (28 passed, 0 failed), which takes
seconds to run. Teardowns stop being the discovery mechanism for permission gaps,
which matters because they happen under time pressure.

**Harder.** Someone has to know what the provider calls on delete, which means
reading provider behaviour or an error message rather than inferring from the
resource schema. The assertions are also inherently incomplete: they pin the
actions we have learned about, so the list grows by incident. And a narrowing that
has not been exercised on the delete path must now be recorded honestly as such,
which makes some existing claims weaker than they read.

**Accepted trade-off.** We accept an incomplete, incident-grown list of
delete-path assertions over either a broad grant or a doubled build cost. We also
accept that "validated" now requires naming the direction, which invalidates the
shorthand used in several existing comments.

## References

- [`../2026-09-10-267.md`](../2026-09-10-267.md) — the source retrospective.
- `terraform/management/irsa.tf` — the `IAMRoles` statement and the comment that
  recorded create-path validation as sufficient.
- `tests/unit/test_iam_resource_scoping.sh` — the source assertion added for this
  class, verified red first.
- `tests/live/checks/negative/iam-resource-scope-denied.sh` — the existing
  create-side deny simulation, which this decision does not replace.
- Beads `kp-2al.21` (the teardown findings, including this one) and `kp-2al.30`
  (the teardown runbook the findings require).
- Commit `6e84258`, applied live by run `34418948661`; after it, every wedged
  resource drained with no manual intervention.
- PRs the decision was made in: #267.
