# Agent Governance adapter (opt-in)

This change adapts the existing planning, implementation and delivery coordinators.
It does not enable governance globally or alter the running X1 service.

The canonical source is `acancelas/bos-agent-governance`, commit
`026923b4d4b9189d38f13aec7b40ab2c681a7f02`. `GovernanceCatalog` reads
`catalog.json` directly from that Git object and checks SHA-256
`2a3932de1ce0c2f868030891366815a7cdda7c0c464058fca959cc2abd7ff7cc`.
Role definitions remain in that repository. A mutable checkout cannot substitute
its own catalog. A missing object fails closed; no automatic network fetch occurs.

`GameApi.Adapter` retains the server's `issue.governance` projection. Its presence
activates the adapter for that Issue; a caller option cannot disable it. Existing
Issues without the projection retain the legacy workflow. Trusted runtime tests
may explicitly opt in with `governance_enabled: true`.

Before implementation, the coordinator prepares the dossier when absent, obtains
all ten applicability decisions, an independent arbiter verdict, and the server's
readiness receipt. An authorized READY resumes without another confirmation.
Goal decomposition can obtain a planning verdict before the existing Goal-level
approval; it does not manufacture readiness or that approval.

After the existing technical checks/reviews, the implementation committee runs
against the exact confirmed candidate. If a committee repair changes the candidate,
the old candidate cannot reach the finalizer: the scheduler resumes technical
validation at the new HEAD. Final integration, closure, deployment and production
verification continue to use the existing backend gates. This adapter does not
write a closure receipt or claim integration/publication by itself.

The dossier is `docs/issues/{issueNumber}/plan.md` plus `manifest.json`, containing
`issueNumber`, exact-byte `planHash` (`sha256:`), `catalogCommitSha`, original scope,
acceptance criteria and requirement IDs. Backend #536 verifies the manifest
against GitHub's canonical requirements. Its full closure dossier remains required.

The normalized backend contract is `kind: governance`, with event-specific fields
at the top level. Never send `actor`, `role` or `payload`; the server derives the
principal and role. `bos_record_governance` writes it; `bos_get_issue.governance`
is the readback. A successful model turn without the confirmed state is failure.
Deterministic operation/governance IDs include Run, phase, event, round, exact SHA,
plan hash and role. Partial committee recovery reuses completed votes and does not
start a new round. Issue-wide planning/implementation counters come from the
server; technical/transport counters and aggregate Goal consumption are never
reset or copied into committee counters. A third round starts only after an
independent exception receipt is visible. There is no fourth round.

## Host session boundary still required

`Application` environment `:symphony_elixir, :governance` can supply `catalog_path`
and `session_broker`. The latter implements `SymphonyElixir.GovernanceSession`
inside the existing host runtime. There is deliberately no default broker:
`BOS_MCP_ACTOR`, a shared service token, or a prompt instruction cannot establish
independent identity. Do not enable this in production with the legacy launcher.

For each callback `run(context, role, prompt, policy)`, the trusted host extension
must provision a fresh existing AppServer session with a distinct verified M2M
subject, server-assigned role and permissions, and effective tool allowlist. It
must check the inherited Goal authorization and aggregate turn budgets before each
turn, account for the turn through the existing runtime telemetry, and enforce the
requested sandbox before starting. Reviewers and the arbiter receive readOnly,
no direct network, only BOS reads plus their narrowly permitted record operations;
scoped MCP transport supplies the authorized gateway access. Coordinator preparation
and repair may use workspaceWrite under the approved scope. Never forward raw
credentials to prompts, logs, artifacts, or the coordinator context. A token or
session provisioning failure must return an error and preserve all state.

This contract is a dependency boundary, not a claim that the unavailable M2M
provisioning is implemented or verified. Live execution, server permissions and
end-to-end READY remain pending secure provisioning and deployment of backend #536
and MCP #246. Tests use an isolated broker fixture; they prove coordinator ordering,
readback requirements and recovery, not the external authentication infrastructure.

Run the required repository check from `elixir`: `mise exec -- mix test`.
The test helper sets a unique temporary outbox and provider-state paths.
