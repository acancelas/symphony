# Issue 69 — Ordinary Desktop activation pilot, 2026-10-15

The bounded Symphony/69 pilot automatically entered the installed managed adapter from an ordinary Desktop request. The existing caller resumed the same Run and planning round after transport-contract corrections. This demonstrates everyday activation for this enrolled installation only; it does not certify other projects or full execution.

## Exact observed binding and evidence

- Candidate: `2bb978f629d1ecf92f30d606816a6e93ceac86ba`; Run: `symphony-governance-69`.
- Plan: `sha256:2d762d9259a24ffd6e313650624c6d10b217ea7e98389c53b1bab00bb960a7a0`; catalog: `ea1d38867fb8096991312d77fd7643e2810ee72e`.
- MCP source: `7d6458cecb308adffe6bda1a4325291c77132b48`; full sealed inventory: 4,152 verified files.
- Host configuration: `6b785d4e49399e31a66c7f8d5fc81474a3862194cad35ce549e470bd78804bcb`.
- Authenticated private readback: `.bos-local/planning-round1-readback.json`, SHA-256 `12d8886086dfd828b94a3da2127550077570a5f5f7bbb7e86458bf08124d7a95`. This host-private artifact contains no credentials and is retained with the active worktree.
- The local API uses canonical source snapshots and an experimental ledger: **canonicalFulfillment=false**. Persisting this report through canonical BOS does not promote the experimental committee into canonical production approval.

## Planning and agent results

Round 1 contains all ten applicability decisions. Product, architecture, security, legal, QA and operations each recorded an original Review. Business Challenger, CRO, SEO and UX recorded justified non-applicability. The independent arbiter persisted `APPROVED_WITH_NOTES`, status `passed`, as `gov_735cd752e45cb40567dcad660f5180decd3eacdf0a424ea8f88dc9312d12536f`, bound to the candidate and plan above. Its notes expressly leave environment evidence, runtime enforcement, durable recovery and later implementation acceptance unverified.

Counters remain planning=1, implementation=0, technical=0, transport=0. No new negotiation round was consumed for the transport correction. Local regression QA on candidate 2bb978f: 481 passed, 0 failures, 6 skipped; this documentation-only follow-up does not change executable source or rerun that candidate's tests.

## Corrected incidents and remaining blockers

The MCP Review descriptor formerly exposed an unstructured object; its diagnostic sanitizer retained GovernanceRecord errors while discarding DeliveryReview errors. MCP 7d6458ce supplies the exact Review contract and selects the appropriate validation branch. The resumed Product Review and subsequent six reviews succeeded. The earlier historical HTTP 403 cause remains unknown; no raw error body was retained. A mistyped 65-character receipt pin was rejected before model startup, then corrected only after independent staging confirmation and full inventory verification.

Readiness stopped at HTTP 409 `governance_environment_evidence_missing`; readiness and closure remain null. No passed environment report exists in the pilot ledger. The host correctly rejects model-asserted passed/verified evidence without exact trusted observations. A host-side producer must execute real scoped environment probes and submit their exact-candidate provenance through the governed contract; this remains separate implementation work and must not be replaced with a manual READY or invented EvidenceReport.

Goal GET HTTP 403 is a separate, expected scope/authorization limitation of the current snapshot: Issue 69 has no parentIssueNumber, no inheritedAuthorization and no bos:goal label; the snapshot provider contains only Issue 69. The legitimate ancestor-chain mechanism cannot resolve an authorized Goal from that data. Backend readiness checks environment evidence before authorization, so fixing evidence alone would still leave authorization missing. Recover the actual authorized Goal relationship through the owner and existing contracts; do not widen permissions or fabricate a parent/approval for convenience.

## Status and retention

Implemented/locally verified: opt-in controller and read-only broker components, bounded ordinary activation and planning pilot as qualified above. Full execution/readiness, workspace-write broker certification and final implementation committee: pending. Integrated: no. Published: no. No production action or new authority was granted.

Keep the registered Issue 69 worktree, private evidence, pinned runtime and API dependencies while coordination remains active. This is a pilot milestone, not final task closure; safe retirement is deferred until owners release the live dependencies and required path/process/Git/ignored-asset/mount checks pass. The original executable candidate remains 2bb978f; a later documentation commit must not be used to claim the same candidate approval automatically.