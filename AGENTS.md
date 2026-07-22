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
- Keep confirmed outbox state bounded: GitHub is the ledger, while local receipts collapse into one atomic sequence watermark per AgentRun.
- On recovery, remove event and batch cache files already covered by the confirmed watermark. A response lost after GitHub acceptance must not leave stale local files looking like pending work indefinitely.
- Apply retention by value: legacy high-frequency telemetry is aggregated per AgentRun, while lifecycle, commands, tools, checkpoints, evidence and failures remain durable.
- Never mutate a recovered hash-chained event in place. Never compact an unconfirmed event out of a sequence; confirmed telemetry may be aggregated, while a damaged legacy pending chain must be rebased atomically from the confirmed GitHub projection and carry its aggregate recovery summary.
- Audit canonicalization must implement RFC 8785 exactly, including lowercase `\\u00xx` escapes and UTF-16 property ordering. Generic JSON encoders are not canonicalizers; keep cross-runtime fixtures for control characters and non-BMP keys.
- Treat provider rate limits as a process-wide circuit across every `game-api` request, not independent per-run or audit-only failures; scheduler reads, heartbeats and a large outbox must not bypass backoff by rotating across repositories or runs.
- Serialize active work per repository. Global concurrency may run Issues from different repositories in parallel, but a running, retrying, or blocked claim reserves its repository so concurrent AgentRuns cannot amplify `bos/audit` compare-and-swap retries.
- Persist repository identity separately from opaque Issue IDs and retain it across capacity waits and retries. `game_api` Issues without canonical repository identity fail closed. This is a local X1 scheduler guarantee; a future multi-runner deployment also needs distributed repository fencing in `game-api`.
- A claimed Issue waiting for worker capacity remains a live lease: heartbeat its original immutable claim identity and reconcile it on every poll. A terminal, missing, unroutable, non-active, or replaced claim relinquishes only Symphony's local reservation; never call the generic tracker release operation from reconciliation because it may overwrite a newer canonical state. Treat an individual Issue `404` as absence, but preserve every reservation when the provider lookup itself fails.
- Use the full 50-event audit contract for non-critical batches to reduce GitHub ref/tree/commit operations. Critical lifecycle and irreversible-boundary events still flush immediately.
- Persist workspace checkpoints to the local outbox immediately, but confirm them through normal 50-event or 60-second batches. A reconstructible diff is durable evidence, not an irreversible boundary, and must not force one GitHub commit per notification.
- Preserve retry-attempt state until a batch succeeds; an expired cooldown permits a probe but must not reset exponential backoff.
- Parse structured `game-api` errors whether the HTTP client returns decoded JSON or a JSON string. Recoverable audit codes must reach the outbox so it can rebase from GitHub instead of retrying a permanently invalid batch.
- Test processes must use an isolated temporary outbox. Never let `mix test` open the live `~/.bos/outbox`; concurrent writers can interrupt an otherwise atomic rebase.
- Tests and runtime cancellation must reap every operating-system child they create; a stopped Elixir task is not proof that its shell descendants stopped.
- Token telemetry must distinguish cached from uncached input and reset provider watermarks when a fresh App Server session starts; budgets and optimization decisions use uncached input, not aggregate input alone.
- Never delete a Git workspace whose state has not been durably checkpointed. Cleanup must fail closed when Git status is dirty or unreadable, or when `HEAD` is not confirmed by its upstream; the next attempt must reuse or reconstruct the same state.
- For BOS Git workspaces, enable `workspace.recover_non_git_directories`: an interrupted partial clone without `.git` is preserved under an adjacent orphan path and rebuilt, never reused as healthy and never deleted as clean.
- Run the required checks in `.bos/project.yaml` after changes.
- A deployment, release, or rollback is incomplete until its exact-commit `DeploymentVerification` passes.
- Keep the deployment critical path short without weakening the contract: reuse still-valid exact-commit evidence, run independent provider/HTTP/version/smoke probes concurrently, and flush non-critical audit detail through the durable outbox. Never make a human wait on a transient provider cooldown; preserve state and retry automatically.
- On startup and every 15 minutes, reconcile every non-terminal AgentRun through the canonical `game-api` operation; startup reconciliation precedes terminal workspace cleanup. Issue closure alone never proves successful delivery; only the gateway may bind exact PR, HEAD, merge, and evidence into a terminal projection. Periodic work must use the shared provider circuit and run outside the orchestrator mailbox.
- The `GameApiTrackerAdapter` must honor the requested state set. Active polling and terminal cleanup use the normalized `issues/by-states` contract; never substitute the eligible-work queue for terminal discovery.
