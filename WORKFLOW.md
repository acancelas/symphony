# BOS Delivery Workflow

Use `bos-mcp` for all product context and durable Delivery operations. Do not call GitHub REST/GraphQL, `gh`, or BOS Delivery endpoints directly from Codex.

Before starting an Issue, recover existing state and resume any active AgentRun, Attempt, workspace, branch, or pull request. Work only on the issue branch, execute every required command from `.bos/project.yaml`, review the diff, and record evidence against the exact commit.

Deployment, release, and rollback remain incomplete until `DeploymentVerification` is `passed`. Credentials, host-specific paths, and X1 runtime configuration belong in secure user or service configuration, never in this repository.
