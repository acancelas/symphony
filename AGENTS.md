# BOS Symphony Agent Instructions

This repository is the BOS-maintained Symphony fork used by the X1 delivery orchestrator.

## Read First

1. `README.md`
2. `SPEC.md`
3. `elixir/README.md`
4. `WORKFLOW.md`
5. `.bos/project.yaml`
6. Nearby source and tests

## Operating Rules

- Preserve upstream Symphony concepts unless the BOS architecture requires a deliberate specialization.
- Use `GameApiTrackerAdapter`; Symphony must not call GitHub REST/GraphQL or hold GitHub credentials.
- Use `bos-mcp` as Codex's exclusive interface for BOS context and durable Delivery operations.
- Keep runner credentials, tokens, and X1 paths in secure host or service configuration.
- Preserve outbox durability, idempotent recovery, automatic command auditing, and exact actor identity.
- Run the required checks in `.bos/project.yaml` after changes.
- A deployment, release, or rollback is incomplete until its exact-commit `DeploymentVerification` passes.
