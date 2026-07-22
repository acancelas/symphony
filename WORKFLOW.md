# BOS Delivery Workflow

Use `bos-mcp` for all product context and durable Delivery operations. Do not call GitHub REST/GraphQL, `gh`, or BOS Delivery endpoints directly from Codex.

Before starting an Issue, recover existing state and resume any active AgentRun, Attempt, workspace, branch, or pull request. Work only on the issue branch, execute every required command from `.bos/project.yaml`, review the diff, and record evidence against the exact commit.

Deployment, release, and rollback remain incomplete until `DeploymentVerification` is `passed`. Credentials, host-specific paths, and X1 runtime configuration belong in secure user or service configuration, never in this repository.

For an explicit deployment request, optimize elapsed time while preserving safety: reuse successful evidence only when it is bound to the exact candidate commit and still satisfies policy; execute independent deployment-verification probes concurrently; persist non-critical audit events through the outbox. Do not rerun unchanged checks merely to recreate evidence. A transient `provider_cooldown` is an autonomous pause-and-resume condition, never a reason to return the task to the user. Critical audit confirmation remains mandatory before merge, release completion, or rollback completion.

Long Codex turns are bounded by role-specific wall-clock and uncached-input budgets. At a soft limit, preserve the current AgentRun, Attempt, workspace, branch, PR, and durable checkpoint; at a hard limit, interrupt the turn and return control to Symphony. A resumed execution must reuse those identities and must not duplicate Reviews or EvidenceReports. Provider rate limiting is a separate pause state and must respect its retry window.
