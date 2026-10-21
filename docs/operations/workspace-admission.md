# Future Symphony workspace admission

The optional `workspace.admission` workflow configuration sends NEW local workspace
creation through the shared host guard. It is disabled when absent. No running
service, installed controller, host configuration or existing workspace is changed
by this source adaptation. Enabling it requires a separately verified future
runner deployment and workflow; source publication is not runtime activation.

The confirmed host release is BOS MCP `33a63d52f154ad8454aec069790d94e0723da7e1`.
Configure the actual canonical repository roots from the project registry, never
from an issue-supplied clone URL, temporary staging directory or feature checkout.
For the published Ubuntu installation the configuration is:

```yaml
workspace:
  root: /existing/legacy/workspace/root
  admission:
    command: /home/dev-agent/.local/bin/bos-workspace
    command_sha256: 56ba885d0be41e09843f5c44dab6f0e31334fad19ec12fc0fad4ab754b72b5d2
    guard_path: /home/dev-agent/.local/lib/bos/bos-mcp-versions/33a63d52f154ad8454aec069790d94e0723da7e1/scripts/workspace-guard.mjs
    guard_sha256: f8c0d9aa4475f4a87f35ceea0d1d7bc7cdcf20101bc1c44fead707699be7db23
    canonical_repositories:
      example: /absolute/registered/principal
```

These pins were read from the installed files/release receipt, not changed by this
work. A future release needs fresh verified pins in that future runner's config;
never repin a running controller. A regular pinned command and guard are required.
The optional `owner` config value is used only when the Issue has no `runId`.
A missing owner or repository scope fails closed. Task IDs are deterministic hashes
of repository ID and original Issue ID, independent of Attempt and display name.
Owner/task labels coordinate allocation; they are not authentication credentials.

The adapter invokes the command with only `create --canonical ... --task ...
--owner ...`, without shell interpolation, a state-dir override or alternate clone.
The production command uses the shared Ubuntu registry. It receives a bounded
response/output deadline; uncertainty requires reconciliation of the same IDs.
The guard fetches `origin/main` for NEW allocation, enforces principal plus three
task worktrees, and returns an existing allocation for the same owner/task.
Capacity/lock/ownership/recovery errors are returned as admission failures; the
caller must queue/retry normally rather than allocate another directory.

The returned path is final. Symphony skips staging, rename and quarantine for
admitted worktrees. `hooks.after_create` now runs THERE only until a successful
inode-bound ready marker is written. A failed setup preserves that same registered
worktree; the next attempt reuses it. Future workflows must replace clone-style
hooks with dependency/setup-only hooks. Git common directory, branch, canonical
path and worktree inventory are checked before using the path, including App
Server validation outside the legacy workspace root. No path is moved to make it
fit the legacy root. SSH-host creation is unsupported in this mode and fails closed.

Managed paths are preserved by direct and recorded cleanup, including after the
opt-in configuration is removed. Automatic terminal cleanup does not retire the
shared registry or free capacity. An owner must verify completion, current-main
content preservation, QA, process/mount ownership, ignored assets and recoverable
commits before explicit safe retirement. No active work is merged or deleted to
free a slot. Existing legacy workspaces retain their original default behavior.

## Verification and limits

The real guard integration test is opt-in through `BOS_WORKSPACE_GUARD_FIXTURE`,
which names a verified guard file (no bundled/copied source). It uses temporary
Git principals/remotes and a temporary HOME for its private fixture registry;
production and the real shared registry are untouched. It passes no `--state-dir`.
Without that fixture setting the real-host integration case is explicitly skipped.
Run it with the published guard to verify actual quota, fifth-task rejection,
same-owner reuse, different-owner rejection, alternative principal rejection and
fresh remote-main SHA while the principal remains on unrelated feature work.
The test also covers setup at the returned path, no staging/legacy creation,
configuration/pin refusal, SSH refusal, path validation and cleanup preservation.

This is implementation evidence for an opt-in future runner, not proof of global
hook trust, activation of existing connectors or a deployed Symphony service.
The historical governance branch's full-coverage/Dialyzer blockers and incomplete
whole-Run certification remain separate, unresolved limitations.

### Recorded local checks (2026-10-21)

- Published guard fixture33a63d52, full suite seed356348:543 tests,0 failures,6 existing skips. Format and mix lint (specs+strict Credo) pass.
- One earlier loaded-suite run hit the existing QA-custody monitor timing assertion; the same-seed focal4 tests and complete543-test rerun passed. The original observation is retained as a limitation.
- Full coverage remains below the unchanged100% requirement:68.53%; all543 tests still pass. Dialyzer still fails with diagnostics; neither check is waived. No claim of full-branch QA acceptance or integration follows.
- The task worktree is retained because governance69 recovery/work and unintegrated changes remain active. Synthetic test repositories are removed by their fixture owner; the canonical project and shared production registry are preserved.
