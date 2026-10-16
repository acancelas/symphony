# Observed DEV snapshot producer (bootstrap, disabled)

GovernanceObservedSnapshot reuses the existing host broker and fixed MCP reads:
bos_get_issue69, bos_get_delivery_run and bos_get_run_history for symphony-governance-69.
Hash the original sole MCP text block before JSON decoding, projection or safe-output
redaction. Re-encoding decoded objects cannot reproduce original response evidence.

The existing Front-generated payload allowlist is loaded by exact byte hash from
host configuration; there is no independently editable producer wire definition.
A release must pin a committed compatible Front contract. A shape-only schema is
not authority: producer additionally verifies authentic HMACv2 source identity,
DEV epoch, Issue/Run/runner/open lease, exact candidate, timeline scope and TTL.
ReadAt precedes all three reads; expiry is min(readAt+60seconds, actual lease).
Only an actual fresh collection can refresh the snapshot. Filesystem/UI rereads
never count as an API observation. Explicit unknown counts stay null/absent.

Raw issue body, comments, logs, prompts and unknown fields are omitted. Free-form
title/summary and actor displayName are not exported: the Issue title is an
explicit descriptive projection label, and summaries use a bounded event-type
label. This is an experimental minimization, not a canonical title/decision copy.
Original byte digests remain available for host-only provenance. String checks
reject common credential material; they do not certify arbitrary text secret-free.
The original source responses remain in host custody, never in the frontend mount.

Publication first writes an immutable observation using GovernanceHostStore, then
uses the same pinned Python runtime for a fixed export file only. Provision a
private0700 directory and permanent0600 .snapshot.lock outside source/Vite roots;
pin both device/inode pairs in host-only custody configuration. No auto-provision,
config activation or arbitrary model file write is provided. All ancestors are
walked with no-follow dirfds. A nonblocking flock, regular single-link private
file checks, fsync, atomic rename and post-rename directory identity checks are
mandatory. Post-replace failures leave an INDETERMINATE marker for offline review.
A narrow read-only DIRECTORY mount lets the frontend see atomic replacement.

This proves neither human authentication nor Docker-port exclusivity. Those stay
with existing human Approval, host execution controls and coordinated local port
ownership. The module grants no gate, READY, integration or production authority.
Real reads, filesystem custody, full QA and browser acceptance remain required
before enabling this opt-in. The caller integration remains owned by the existing
broker/lifecycle, not a separate service or poller.

## Explicit refresh entrypoint (disabled until host configuration is accepted)

`refresh(context, settings, execution, fetch)` combines the existing operations.
Nil/empty settings or explicit `enabled: false` return `{:ok, :disabled}` without
calling the callback, loading a contract or invoking a publisher. A malformed
nonempty opt-in fails closed. The enabled atom-keyed settings have exactly
`enabled`, `contract_path`, `contract_sha256`, `provenance` and `custody`; execution
reuses the existing HostStore/Python configuration. No credential copy or second
wire definition is introduced.

Before reads, validate the enrolled Issue/Run/candidate, paths, custody pin shapes,
Python byte pin and existing Front contract byte pin. Then collect the three fixed
raw MCP text blocks, build with the real collection time and publish through the
existing immutable HostStore/atomic writer. Return only bounded export metadata:
candidate, epoch, read/issue/expiry times, payload/export digests, immutable host
observation ID and the fixed filename. Raw responses and the payload are not
returned by this entrypoint. The stored observation remains the minimized basis;
this projection does not add a new archive of full raw API responses.

The exact publisher receipt must match the serialized envelope. If the lease/TTL
expires during publication, return an error without extending the timestamps or
deleting a possibly newer concurrent export. The consumer must independently
reject an expired file. A filesystem/UI reread performs no API collection. A new
refresh invokes all three reads again; replay of an identical immutable envelope
still uses the existing publisher's idempotence. No retry loop, queue, timer,
approval or canonical task transition is added.

## Isolated integration evidence, not live acceptance

Root's five new refresh cases plus five existing module cases pass: ten tests,
zero failures, seed467854. They exercise disabled/no-call behavior, invalid scope
and pins before reads, exact fixed callback arguments/original text hashes, real
temporary private-file export and immutable-basis linkage, fresh recollection,
failed reads/authentication and rejected custody. All responses are synthetic
fixtures; no API69, real custody directory, browser, claim or gate was used.

Compilation emitted the new module only into the Root-owned
`snapshot-producer-root-build/ebin`; the test process asserted that exact code
path before exercising `refresh`. The compiler's old-module redefinition warning
is retained in the original log. The privileged shared build was not a compile
target and its complete1,246-file receipt was independently reverified afterward.
Focused log SHA256
`c770cb754002ead92bf22d5dc9240bded629d9a35bee133824dd5dd5487fe430`.
Module source SHA256
`6fad4d93d3e60f05233c2465866b62b11d4752d2c827cbfb5fb22dd269d2897e`;
test source SHA256
`cfc3b4640e16590bd02f91bc1f359ef977e3349e3a274431ae9d10f37c431f8e`.
The original first-pass log/report are retained separately. Broker HostConfig and
lifecycle hooks, canonical full suite, independent source assessment, current
schema interoperability and actual host/Docker/browser E2E remain pending.


## Optional configuration and existing readiness lifecycle

The private host configuration accepts `observed_snapshot` with only `enabled`,
`contract_path`, `contract_sha256`, `provenance` and `custody`. Missing/null/empty
or explicitly disabled settings perform no snapshot reads or exports. Enabled
settings require all five keys. Only these outer setting keys become atoms;
provenance and custody retain their existing string-key contracts. Execution
settings continue to come from the existing `execution` object.

The existing broker readiness preparation invokes `refresh` after confirming its
readiness evidence and effective principal. Its fixed host callback is
`host_snapshot_read`; it is not exposed as a model tool. Any enabled refresh
failure prevents successful completion of that readiness preparation. An export
never supplies authority or satisfies the canonical readiness gates.

The parser and refresh tests pass together:13 tests, zero failures, seed684978.
This is synthetic isolated evidence. The installed host configuration has not
been changed and the producer freeze remains in force. No actual API69 read,
export, mount, approval or readiness transition was performed.

Full source suite after caller integration:524 tests, zero failures, six existing
skips (seed17932); formatting check passes. This does not certify the pending
native QA sandbox or actual host/API/browser effects.
