# ADR: End-to-end tests run from an EC2 instance inside the VPC driven by SSM, not from the sandbox or a GitHub self-hosted runner

- **ID**: ADR-520997d08c
- **Status**: Draft (not yet adopted to docs/adr/)
- **Date**: 2026-09-09
- **Source retrospective**: ../2026-09-09-263.md
- **PRs covered**: #263

## Context

Step 5's hold-out test suite must exercise the platform the way an admin, a tenant and an end user would. The Claude Code sandbox cannot reach the clusters' private endpoints (an SSM relay exists only to work around its egress gateway) and cannot be assumed to have a VPN. The owner will have direct VPC access and asked that tests run from inside the VPC instead of working around sandbox limits. The agent proposed a GitHub Actions self-hosted runner on that instance; the owner was wary of debugging workflow YAML while also finding infrastructure bugs.

## Decision

The hold-out end-to-end suite runs as plain scripts on a small EC2 instance in the base VPC, triggered by SSM send-command and debugged through a Session Manager shell, with no GitHub self-hosted runner unless run-ID evidence later proves worth the extra moving part.

The instance follows the pattern of the existing SSM kube relay one notch larger; its instance profile assumes the scoped verifier role for read-only tiers and a mutating role for the instantiate tier, mirroring `live-verify`; output goes to the state bucket; a person debugs by opening a Session Manager shell and running the same script.

## Alternatives considered

- **GitHub self-hosted runner on the instance** — gives run IDs, retained logs and a UI, but adds the runner agent and its registration token as moving parts and invites logic to creep into workflow YAML where it cannot be run by hand; deferred, and the scripts do not move if it is added later.
- **Run the suite from the sandbox through the SSM relay** — works for the hub and for read-only checks, but keeps the sandbox on the critical path and cannot reach private endpoints the way an admin would; rejected.
- **Run the suite from the owner's VPN-connected workstation** — matches the admin's view exactly but is not agent-drivable and not reproducible; kept as the manual fallback.

## Consequences

Easier: tests see the platform from inside, agents trigger them with one AWS API call, humans debug with a shell and the same script. Harder: the instance is one more thing rebuilt with every account; evidence is an SSM command ID plus an S3 object rather than a GitHub run ID; instance count rises to six of the nine the sandbox account allows. Accepted trade-off: a plainer, more debuggable path over integrated CI evidence.

## References

- [`../2026-09-09-263.md`](../2026-09-09-263.md) — the source retrospective.
- `ai/roadmap.md` "Step 5 shape"; `planning/scenario-corpus/charter.md` (to be amended in the step 5 planning session); beads `kp-e5n.7`, `kp-e5n.8` (sketches, gated).
- PR the decision was made in: #263.
