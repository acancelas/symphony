# Read-only implementation proposal and host publication

Status: implementation design, not an active or certified execution route.
Root selected this route after actual native future-policy-file creation failed
and the exact-file sandbox prototypes failed before their canaries. Preserve
those original failures. No native workspace-write certificate is inherited.

## Authority and approved paths

The implementation worker must use the already measured read-only native role
boundary, with original policy material supplied by the host. Changing its
sandbox to read-only must never take the existing generic no-admission branch:
implementation is identified by the host phase/role and still requires current
human DEV authority, lease, approved exact plan, admission, budgets, single-use
launch ownership and effective principal checks.

The current manifest only binds the Markdown plan digest; it supplies no
machine-readable approved-file inventory. Do not derive new write authority
from model output or a mutable manifest-only field. Add a strictly parsed,
versioned file list inside the hashed plan itself, and require independent
approval of that exact new plan before use. Missing/ambiguous lists fail closed.
Do not rewrite the existing approved plan or transfer its votes automatically.
The host reads the approved baseline plan from exact Git objects and checks its
canonical digest, baseline ancestry and current server authorization.

## Proposal and compare-and-swap

Extend existing CandidatePublication, not a new service or model write tool.
The worker returns one bounded structured proposal containing exact candidate,
plan digest and changes with path, expected original Git blob and UTF-8 content.
Only paths in the approved hashed plan and existing publication restrictions are
eligible. Reject duplicates, policy names, dot/secret paths, traversal,
symlinks/hardlinks, unsupported original modes, excessive bytes and any unknown
field. Keep raw proposal bytes private; sanitized logging must not alter the
source bytes later applied.

After the actual admitted worker is reaped, use the existing permanent source
publication lock. Recheck authority outside the lock, then exact HEAD, clean
index/worktree and every source blob/content under the lock. Validate all
changes before writing any file. Persist a single-use prepared intent through
the existing HostStore before replacing files; use pinned fixed host Python,
anchored no-follow directory descriptors, exclusive temporary siblings and
fsync. No arbitrary shell, MCP write or caller-supplied executable. Any uncertain
partial application fences the intent as indeterminate; never retry it as a
fresh invocation or infer atomic multi-file success.

Existing fixed trusted QA and final committee must evaluate the resulting exact
candidate. Source publication and final acceptance remain separate. Whole-Run
metering, deadline and cancellation must span worker, host application, QA and
final review sessions; current premature Attempt completion must be corrected.

## Required independent verification

Exercise wrong plan/hash/candidate/blob, unapproved paths and mixed valid/invalid
batches without writes; policy/secret/link attacks; concurrent publishers;
termination after prepared intent or individual replacements; stale authority;
actual native read-only effective scope, denied native writes and process reap;
trusted fresh QA cache and complete multi-session meter-to-ledger accounting.
None of these obligations is satisfied by this design document.


## Preparatory source checks

Existing CandidatePublication now has side-effect-free `proposal_paths` and
`validate_proposal` helpers. The former checks current authority and reads a
single canonical JSON `bos-implementation-files` block from the exact approved
baseline Git plan. The latter checks the exact candidate and plan, all targets,
original Git blobs, regular-file shape, clean worktree/index, duplicate/unknown
fields, UTF-8/NUL and byte limits before returning the proposal unchanged.
Neither helper writes files, starts a worker or consumes a launch. No lifecycle
caller enables this route yet. The existing plan was not changed or reapproved.

Ten authority/publication tests pass (seed601539), including a mixed valid plus
unapproved batch leaving source and index unchanged, wrong blob/candidate,
duplicates, NUL content, extra commands, changed working files, unapproved plan
inventories and actual policy filename rejection. Public specifications pass.
The first two new tests exposed an iodata-to-binary mismatch in the test setup;
the helper comparison and fixtures now explicitly convert canonical iodata.
CAS persistence/application, process reaping, pipeline wiring, fresh trusted QA,
whole-Run accounting and independent acceptance remain pending.

Full suite with these preparatory helpers:527 tests, zero failures, six existing
skips (seed88091); formatting passes. Overall lint still fails on outstanding
style/refactoring findings and has not been waived.


## Host CAS application prototype

`apply_proposal` now requires implementation phase, current bound admission,
current boot and a COMPLETED existing execution journal whose actual child PID
is absent (only ENOENT counts). It rechecks retirement under the existing source
publication lock, validates the whole proposal and clean tree, pins the workspace
device/inode and creates a single-use immutable PREPARED observation keyed by the
existing execution journal identity. Another proposal or restored source cannot
reuse that worker's application slot.

The existing pinned host Python executes a fixed embedded writer with no inherited
environment, script path or shell. It anchors directory descriptors, rejects
links/unsupported modes, compares every original blob and inode before replacing
any target, fsyncs exclusive temporary files and directories, rechecks deadlines
through replacement, and verifies final named-path content and parent identities.
The deadline is bounded by admission, lease and current observation freshness.
Outcome observations record APPLIED or INDETERMINATE. An uncertain operation is
never retried or treated as an atomic multi-file transaction; a partial write
requires explicit technical recovery. Publication/QA/acceptance remain separate.

Two additional isolated tests use an actual inert journalled child and temporary
private source/store/guard paths. They verify live-child denial, application after
actual stop/journal completion, rejection after restoring the original source,
and mixed-batch rejection before any intent or target mutation. Twelve focused
tests pass (seed164159); the final full suite passes529 tests with six existing
skips (seed596468). The first application test caught two accidental embedded
NUL literals in the new fixed helper argument; escaped Python literals corrected
them before any commit. The failed fixture returned indeterminate, never success.

No real native implementation worker, production source, API69, installed config
or authoritative approval was used. This prototype is not yet wired into the
broker. Actual abrupt death/persistence recovery, complete descendant custody,
shared host/API namespace, revocation races and independent review remain
mandatory. Preserve the old rejected native write profile and first SEC1 result.


## Broker wiring checkpoint

Primary execution and derived repairs now share one fixed read-only policy with
source tools and a strict structured proposal schema. Native commands/writes and
model MCP mutations are rejected; role identity and full execution admission
remain required. The explicit implementation scope is dispatched before the
ordinary read-only review path, so changing sandbox type cannot bypass admission.
Current primary proof, separate QA proof and a file inventory inside the newly
approved hashed plan are required before starting an Attempt. Existing votes or
old workspace-write canaries cannot supply those prerequisites.

The broker supplies complete original scoped policy material, disables automatic
project-document discovery, checks the actual read-only/never/network-disabled
thread response and fsyncs that same-session scope before inference. It retains
raw structured source bytes privately. After inference it stops the actual
worker, waits for PID absence, completes its local single-use journal, applies
host CAS, verifies exact staged proposal contents and invokes fixed QA with the
independent monitor's bounded health check.

The monitor now owns the QA port and forwards its output to the logical Run
owner. Authority/budget failure or owner death reaps that port as well as the
retired primary's port. A real inert-process test kills the logical owner while
the BEAM host remains alive and verifies QA PID absence. A separate test checks
exact transport output forwarding. These are custody primitive tests, not full
admitted-native/whole-Run acceptance.

The previous premature `bos_complete_attempt` path has been removed. Source
publication is deliberately blocked before any Git mutation while source handoff,
aggregate metering across every review session and final settlement remain
unimplemented. No successful primary/QA substep is reported as whole-Run success.
The current environment remains unconfigured for actual69 execution.

## Separate read-only QA integration

Root delivered NativeCommand with strict proof preflight, source RO, exclusive
fresh cache, private network/PID namespace, own loopback and fixed repository QA.
Original Root handoff source3fc94cf1/test5c157bbc and its two tests/probe716dd910
remain historical supporting evidence; no installed configuration changed.

Integration added independent port custody and a QA-specific source audit that
skips only real output directories (`_build`, `bin`, `cover`) fully hidden by the
fresh cache overlays. The primary's stricter audit remains unchanged. Unsafe
source links and symlinked output mountpoints still fail. This addresses existing
Mix build aliases without making their old contents visible to QA.

A new actual no-model probe calls the current production `sandbox/3`, includes an
old output-cache alias and passes all required checks, with process reaped.
Report SHA256 `8b72b2a83c7adcf4c6b09a3d9c27595c8b79bd70ea8d3cb50b68467ae17dac5c`;
QA recipe `bb44d945ae17032769afd92e61785a216b7bcef44df41655c6dd491295c2a604`.
The original failed probes and isolated cache-policy creation observation remain
unchanged. The cache has no model and project instruction autoload is disabled;
cache policy creation is not claimed denied. Actual full repository QA inside
this namespace, primary current-recipe model canary, final independent committee,
shared namespace and whole-Run proof remain pending.

## Actual observation contract interoperability

The host constructor now emits the exact existing536 accounting envelope:
`Host runtime observation`, empty checks, inconclusive runtime criterion and one
observation. Unknown charges remain null; terminal reaping is derived from the
actual process/boot; retired children cannot be reported running. No raw marker
is exported. The earlier host criterion text/checks mismatch was corrected.

Backend536 consumed three artifacts emitted by the actual Elixir constructor,
without repairing their JSON, through its signed in-process HTTP handlers:
running200, worker_stopped200 after actual reaping, and unknown charge_only200
after revocation, retaining lower bounds and prior current observation. The
isolated proof SHA256 is7294b60f86a3a6407d4e970926d3ce9a4cc927278ed292a34ecbd965b5ac839b;
its constructor-source pin is4f7df1d6460e7826a151d2002d88b040c24d43d520d1d8a5a659437081850024.
Later module changes cover readiness wiring/refactoring; this prior full-file
pin is not presented as acceptance of the later module. No live API/container,
canonical human approval, model invocation or536 source edit was involved.
