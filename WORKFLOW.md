# BOS Delivery Workflow

Use `bos-mcp` for all product context and durable Delivery operations. Do not call GitHub REST/GraphQL, `gh`, or BOS Delivery endpoints directly from Codex.

Before starting an Issue, recover existing state and resume any active AgentRun, Attempt, workspace, branch, or pull request. Work only on the issue branch, execute every required command from `.bos/project.yaml`, review the diff, and record evidence against the exact commit.

Deployment, release, and rollback remain incomplete until `DeploymentVerification` is `passed`. Credentials, host-specific paths, and X1 runtime configuration belong in secure user or service configuration, never in this repository.

For an explicit deployment request, optimize elapsed time while preserving safety: reuse successful evidence only when it is bound to the exact candidate commit and still satisfies policy; execute independent deployment-verification probes concurrently; persist non-critical audit events through the outbox. Do not rerun unchanged checks merely to recreate evidence. A transient `provider_cooldown` is an autonomous pause-and-resume condition, never a reason to return the task to the user. Critical audit confirmation remains mandatory before merge, release completion, or rollback completion.

Long Codex turns are bounded by role-specific wall-clock and uncached-input budgets. At a soft limit, preserve the current AgentRun, Attempt, workspace, branch, PR, and durable checkpoint; at a hard limit, interrupt the turn and return control to Symphony. A resumed execution must reuse those identities and must not duplicate Reviews or EvidenceReports. Provider rate limiting is a separate pause state and must respect its retry window.

Before implementation, a Goal must have a complete versioned
`GoalExecutionProposal`. One `GoalExecutionApproval` authorizes every listed
Capability and Issue and any strictly derived repair tied to an approved acceptance
criterion. Symphony evaluates that inherited authorization, proposal version,
repository list, execution window and aggregate Goal consumption before claiming
work. It does not request approval for child Issues, retries, reviews, CI, PRs or
reversible delivery actions inside the approved contract.

## Autonomous execution protocol

An explicit user request for an outcome through production is the authorization
intent for the complete in-scope delivery path. Once that intent is bound to the
approved Goal proposal, it covers local edits, temporary environments and database
branches, non-destructive migrations described by the contract, repairs, tests,
reviews, commits, PR creation, CI, merge, the single governed deployment and
exact-commit production verification. Agents must not ask for a second approval for
any of those predictable intermediate steps. The intake agent may bind the user's
authenticated request to the exact reviewed proposal as the single
`GoalExecutionApproval` without another confirmation when the proposal does not
materially change that request. Agent-proposed improvements and expanded scope never
inherit this intent and still require an explicit human decision.

A failed command, test, build, temporary migration, review or deployment probe is
work to repair and retry. It is not a human blocker. A Codex turn or Attempt limit is
a checkpoint boundary: preserve the AgentRun, workspace, branch and evidence, then
resume automatically. Never mark a Goal blocked merely because an intermediate
attempt failed or a bounded turn ended while approved acceptance criteria remain.

Human input is reserved for a material scope or acceptance change, a new destructive
or data-loss boundary, missing credentials or external authorization that cannot be
recovered automatically, an irreversible action outside the approved contract, or a
new permissions, privacy, billing or risk decision. A real escalation must identify
the exact new decision; otherwise Symphony keeps the Issue active and continues.

Goal ceilings include implementation, reviewers, repairs, validation, evidence and
MCP coordination. At 75% Symphony freezes scope; at 100% it starts no new turn.
Pausing when the window closes preserves the approval and remaining budget.
Functional and quality review are automatic; architecture, security and visual
review are risk-adaptive. No more than two repair cycles may run.
