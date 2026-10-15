# Agent Governance adapter (opt-in)

This change adapts the existing planning, implementation and delivery coordinators.
It does not enable governance globally or alter the running X1 service.

The canonical source is `acancelas/bos-agent-governance`, commit
`ea1d38867fb8096991312d77fd7643e2810ee72e`. `GovernanceCatalog` reads
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
readiness receipt. Readiness references exact-candidate evidence with typed
`phase: readiness`, environment-only acceptance criteria and an environment
check `id: environment`, `status: passed`, `verified: true`; no caller readiness
flag substitutes for that server check. Readiness evidence cannot satisfy
implementation or closure, and never asserts unimplemented business acceptance. An authorized READY resumes without another confirmation.
Goal decomposition can obtain a planning verdict before the existing Goal-level
approval; it does not manufacture readiness or that approval.

Required repository QA remains mandatory. For governed Issues, the canonical
implementation committee replaces the legacy specialist-session orchestration;
legacy Issues keep their original path. The exact candidate and passing original
evidence bind the canonical committee. A committee repair requires new exact-head
validation/evidence before approval. Only a scoped coordinator session can finalize
after the committee; it cannot grant approval or bypass backend integration,
closure, release or production verification gates.

The dossier is `docs/issues/{issueNumber}/plan.md` plus `manifest.json`, containing
`issueNumber`, exact-byte `planHash` (`sha256:`), `catalogCommitSha`, original scope,
acceptance criteria and requirement IDs. The controller copies `definitionDigest`
from the signed scoped Issue readback; it covers the exact GitHub body bytes,
including visible Markdown and the hidden marker. It rechecks this binding after
drafting. A changed definition, including Markdown-only changes, stops the flow
without rewriting an existing manifest. Missing or invalid existing dossiers are
not silently regenerated. Goal dossiers also copy `goalBreakdownHash` directly
from scoped `get_goal_planning`; no duplicate production hashing implementation is
used. Changing Goal capabilities invalidates the bound committee proof.
The manifest also archives `requestSnapshot`: host-built number/title/URL,
createdAt when available, complete sanitized body, original definitionDigest and
provenance. The draft cannot supply this source record. Existing original snapshots
remain unchanged; explicit host-adopted revisions append to `requestRevisionSnapshots`
without replacing that original. Secret/header/private-key patterns use the existing
audit redactor plus snapshot-specific contact redaction; comments, author profiles
and unrelated personal data are not copied. No raw body is written to Git.
Backend #536 verifies the manifest
against GitHub's canonical requirements. Its full closure dossier, including the existing readable request section, remains
required. The additional snapshot is an archive, not a substitute for that section
or a claim that backend #536 certifies snapshot semantics/redaction. Model prose
must not replace the original archived definition.

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

`Application` environment `:symphony_elixir, :governance` supplies `catalog_path`,
`session_broker` and `coordinator_repositories`, e.g. a host-owned map from canonical
repositoryId to `%{token_env: "HOST_SCOPED_COORDINATOR_JWT"}`. No credential value
belongs in a repository. The existing normalized HTTP client uses `Authorization:
Bearer` from that environment reference for the configured repository, removes the
legacy shared-token/claimed-actor headers, and omits client auditBatch on governed
artifacts. The server verifies the signed M2M subject, role, permissions and repo.
A configured repository cannot silently fall back to legacy execution if its Issue
projection is missing. Missing coordinator credentials fail before claim.

The scheduler's lease only reserves work. `start_coordination` creates/reuses the
existing AgentRun without an implementation Attempt. The read-only drafting session
returns data; the controller validates exact keys and writes/commits only fixed
`docs/issues/{issueNumber}/plan.md` and `manifest.json` paths. Extra file requests,
symlink destinations and unrelated dirty work are rejected. After committee and
environment READY, Goal authorization is rechecked and the existing start_execution
creates the implementation Attempt; product sessions use the scoped broker rather
than default AppServer credentials. No second workflow state machine is introduced.
Goal planning uses the canonical independent committee, not the legacy
breakdown-review endpoint which scoped reviewer tokens intentionally cannot call.

The host `session_broker` implements `SymphonyElixir.GovernanceSession`
inside the existing host runtime. There is deliberately no default broker:
`BOS_MCP_ACTOR`, a shared service token, or a prompt instruction cannot establish
independent identity. Do not enable this in production with the legacy launcher.

The broker implements `identity(context, role)` returning the public verified
`machine_id`, server-bound `role` and canonical `repository_id`, and
`draft(context, prompt, policy)` returning only a plan/manifest object from a
readOnly session. Those public identity details are injected into prompts so
Review/Attempt actor fields use the exact M2M subject, never a guessed role name.
The server remains the authority; a callback's strings are not proof of live auth.
For each callback `run(context, role, prompt, policy)`, the trusted host extension
must provision a fresh existing AppServer session with a distinct verified M2M
subject, server-assigned role and permissions, and effective tool allowlist. It
must check the inherited Goal authorization and aggregate turn budgets before each
turn, account for the turn through the existing runtime telemetry, and enforce the
requested sandbox before starting. The `capabilities(context, role)` callback must
report enforcement of tool allowlists, minimal environment, restricted read roots,
private MCP credentials and readOnly where requested. Missing capabilities fail
closed. These host attestations are a contract boundary, not an external sandbox
certificate: deployment requires actual negative tests against host/human/provider
secrets and unauthorized file reads/writes. The agent process must never inherit
any MCP token; only its private scoped MCP transport receives that credential.
Ambient service, human and coordinator secrets must be stripped, and read roots
limited to the task workspace. A platform that cannot enforce these controls
cannot certify independent review. `tools` is the MCP allowlist;
`native_operations` bounds native reads, workspace edits and local validation
separately. Review/arbiter native operations are limited to reads. Reviewers and the arbiter receive readOnly,
no direct network, only BOS reads plus their narrowly permitted record operations;
scoped MCP transport supplies the authorized gateway access. Preparation and planning revisions remain readOnly; only the controller writes
the fixed dossier files. Implementation/repair may use workspaceWrite only after
READY under the approved scope. Never forward raw
credentials to prompts, logs, artifacts, or the coordinator context. A token or
session provisioning failure must return an error and preserve all state.

This contract is a dependency boundary, not a claim that the unavailable M2M
provisioning is implemented or verified. Live execution, server permissions and
end-to-end READY remain pending secure provisioning and deployment of backend #536
and MCP #246. Tests use an isolated broker fixture; they prove coordinator ordering,
readback requirements and recovery, not the external authentication infrastructure.

Run the required repository check from `elixir`: `mise exec -- mix test`.
The test helper sets a unique temporary outbox. Bootstrap tests use a fresh Git
fixture and no preseeded governance artifacts, exercise the real tracker/client and
coordinator order, reject early Attempts and unsafe draft writes, and check exact
public machine subjects in Reviews. They do not certify external M2M infrastructure.

## Actual host availability

Phase 3's concrete AppServer session broker remains pending, separately from M2M
credential provisioning. Installed native probes failed certification: WSL aborts
on a bwrap integrity mismatch, and the isolated Windows standalone command/exec
route allowed the synthetic outside read and write. This is not a claim about all
Windows turn/tool paths. No global fix or guard bypass was attempted. See
`docs/governance-runtime-probe-2026-10-15.md` for exact provenance, a repeatable
no-model canary script and the compatible vendor-verified runtime/profile route.
The callback/test fixtures must never be described as a working host broker.

### Concrete private host broker (isolated DEV pilot)

`GovernanceAppServerBroker` launches the pinned native AppServer directly, with
an explicit named read-only permission profile, an empty task runtime directory,
and a minimal environment. Original candidate files remain in the existing Git
worktree and are available through bounded, sanitized host Git-object tools.
The model never receives the private MCP service credential or chooses its
logical execution identity. Service authentication reuses the existing BOS host
HMAC registry; it does not require a Clerk account or machine for every role.

The private MCP process is a separately pinned build: a host-pinned SHA-256
receipt covers `dist`, dependency files and package lock, sealed directory
inventories reject added imports, and the Node executable has its own pin.
Every host tool call first rechecks the uncached server identity and complete
immutable scope. Connections are versioned by phase, plan and candidate; closing
a role session closes its older versions while preserving other Runs.

Runtime preparation probes are prerequisites, not certification of this broker.
The local backend pilot explicitly uses synthetic Issue/Git/ledger provider data;
HTTP authentication and actual native tool observations cannot establish canonical
committee acceptance, human approval or Goal fulfillment. Workspace-write native
launch and ordinary desktop automatic activation remain pending. The existing
legacy daemon acknowledgement and all Delivery gates remain unchanged.

The protected one-shot entrypoint is:

```sh
bin/symphony governance --host-config /private/governance-host.json \
  --phase planning --workspace /registered/task/worktree \
  --repository symphony --issue 69 --run symphony-governance-69 WORKFLOW.md
```

The host configuration is a mode-0600 JSON file with `service_subject`,
`service_secret_file` (a path to the existing registry, never the secret),
`catalog_path`, `allowed_authenticated_by` (`["bos-host-hmac-v2"]`),
`repositories` (ID to exact repository identity), `workspaces` (ID to authorized
registered task worktrees), `api_base_url` (loopback DEV only),
`target_project_id`, `private_home`, `private_cache_root`, `mcp` and `runtime`.
`mcp` supplies the executable/entrypoint, full build receipt root/path/SHA-256 and
Node executable SHA-256. `runtime` supplies the native package receipt, binary and
proof paths/hashes, vendor/auth/worker roots, audited native config SHA-256 and the
complete `disabled_mcp_servers` name list. Provider names are explicitly disabled
before initialization; an empty table alone merges inherited servers. Preflight
rejects active providers and nonempty hook handlers while accepting the native
serde representation of empty hook arrays.

This command reuses the existing AgentRun and server-derived runner, reserves it
through the existing claim API, confirms the active claim and branch, and runs the
existing coordinator. It starts no scheduler and creates no implementation
Attempt. A planning result is `ready` only after the coordinator's authoritative
readback; a Goal planning committee without execution authorization can report
`phase-passed`. Invalid configuration or any gate failure returns `blocked`.
Candidate publication uses the configured, server-verified repository explicitly,
without changing the shared checkout's `origin`. The legacy daemon entrypoint
retains its existing acknowledgement requirement.

The historical concrete liveness report is
`docs/governance-concrete-broker-probe-2026-10-15.json`: actual native tool events
read the same original Git SHA through both source tools. It intentionally marks
`brokerCertified: false`; full committee/desktop activation and final build
re-pinning remain separate acceptance work.

The concrete host rejects model-submitted passed/verified EvidenceReports unless
the entire artifact matches host-observed evidence for the current scope. Signed
origin alone cannot prove an environment observation. Self-report, altered reports,
stale commits and other Runs are rejected. Full readiness remains pending actual
host environment results, runtime certification and independent Goal authorization.
