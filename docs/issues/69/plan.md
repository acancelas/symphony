# Adapt BOS Agent Governance in Symphony coordinators

## Original requirements

The original BOS request calls for opt-in planning and implementation committees using a pinned catalog, independent reviewers and arbiter, durable recovery and authorized continuation. Its scope is existing Symphony coordinators, portable bos-orchestrator configuration and local isolated tests. Production, global enablement and closure of the originating BOS MCP issue are excluded.

The acceptance criteria are: verified catalog commit; all ten committee applicability decisions; independent readOnly review and independent arbiter; two rounds with a third only after prior justification; recovery preserving IDs and Goal budgets; and legacy opt-in compatibility.

## Planned work

1. Verify the canonical catalog and its integrity against authoritative BOS context. The original request references commit `1682995de8d50361eba262fdacb51e98669c9cc1`, while current authenticated context identifies a different revision. Resolve that discrepancy through authoritative verification before treating either revision as the approved pin. Use catalog definitions directly rather than inventing committee roles or authority.
2. Adapt the existing planning, implementation and delivery coordinators to the governed path. Preserve the existing workflow for Issues outside governance opt-in, and keep configuration portable with credentials held by the host.
3. Prepare the original scope and requirement bindings for controller validation. Obtain and persist all ten committee applicability decisions. Run applicable reviews in independent readOnly sessions, followed by an independent arbiter, using verified server-bound identities and scoped permissions.
4. Enforce two normal committee rounds. Require prior justification and a confirmed independent exception receipt before starting a third; reject any fourth round. Keep technical and transport retries separate from committee counters.
5. Recover from confirmed BOS state using stable operation identities. Reuse completed decisions and preserve existing Run and Attempt identities, original requirement bindings and aggregate Goal consumption. Retry partial failures without duplicating votes or resetting budgets.
6. Continue implementation only after authoritative readiness and the existing Goal authorization checks pass. Preserve backend delivery and closure gates. Fail closed when required identity, catalog, permissions or confirmed state is unavailable.
7. Validate the integration with local isolated tests covering catalog integrity, all ten applicability decisions, reviewer and arbiter independence, readOnly enforcement, round limits, interrupted recovery, preserved IDs and budgets, authorized continuation and legacy compatibility. Run the required repository checks with an isolated temporary outbox.

## Completion evidence

Map each original acceptance criterion to test results and confirmed BOS state where applicable. Distinguish local fixture evidence from live authentication or readiness evidence; local success alone cannot establish production readiness or Goal fulfillment.

## Draft boundary

This response supplies only the draft plan and manifest. The controller supplies issueNumber, planHash and catalogCommitSha and validates the original requirement binding. This drafting step performs no product implementation, file creation, deployment or approval.