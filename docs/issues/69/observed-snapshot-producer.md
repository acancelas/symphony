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
Actual producer wiring, real reads, filesystem custody, Front interoperability,
QA and browser acceptance remain required before enabling this opt-in.