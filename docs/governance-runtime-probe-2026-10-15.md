# Installed runtime certification probe — 2026-10-15

Status: **not certified**. Phase 3's concrete host session broker is not implemented
or installed. The candidate implements coordinator adaptation, signed per-repository
metadata transport, fixed-path dossier writes, callback contracts and test fixtures.
That is separate from the missing host broker implementation, real isolation proof
and twelve securely provisioned M2M subjects. Production authorization is outside
this work and is not the cause of this blocker.

The repeatable probe is `scripts/probe-governance-runtime.py`. It invokes only
`initialize`, `config/read` and `command/exec`, without a model, inference login,
real credentials or global configuration changes. It creates a temporary empty
CODEX_HOME, a synthetic workspace, an outside synthetic canary and a synthetic
parent environment secret. It selects a custom permission profile (root deny,
minimal runtime read, workspace read, network disabled, no legacy sandbox settings),
then requests `command/exec.permissionProfile = "bos-review"`. No sandboxPolicy is
combined with permissionProfile. The generated installed CommandExecParams schema
recognizes this field. Each process is stopped/reaped before fixture cleanup.

## Observations

Both runtimes reported the profile selected and no effective legacy sandbox override.
The final probes used task-owned scratch under Documents/Codex/work, outside platform
temp roots, to avoid relying on any implicit temporary-directory access.

| Runtime / route | Actual observation | Consequence |
| --- | --- | --- |
| WSL `codex-cli 0.145.0-alpha.18`, `command/exec` | Child exit 101, bundled bwrap integrity check aborts; canaries unchanged | Cannot demonstrate command sandbox enforcement on the current WSL runner |
| Native Windows `codex-cli 0.162.0-alpha.17.2`, `command/exec` | Command exit 0; workspace read true, outside read true, workspace write true, synthetic parent-secret visibility false | This probed route fails certification for a read-only workspace boundary |

The Windows result is specific to standalone command/exec. It does **not** prove
that every Windows Codex turn or shell-tool route ignores sandbox policy. No
model-backed turn or Windows sandbox setup was invoked. A real host broker needs
its actual turn/tool path tested; this probe is not a substitute for that proof.

The WSL binary is a regular file at `/home/dev-agent/.local/bin/codex` (not a
symlink). Its companion `/home/dev-agent/.local/bin/bwrap` has SHA-256
`52231e1caf55bcbc667b269f49c63599a6f7db4767ae6a039580d0ff853db712`, while the
installed binary requires
`77360cb751ccedc5971391444ac86a8a33c15b04d6b4a6fe45f5d25496e62c4c`.
A direct `codex sandbox linux -- /bin/true` independently produces the same
integrity failure. No integrity check was bypassed and no binary was replaced.
A bounded read-only filename scan of the usual local/mise/npm/cache/vendor paths
found no original verified CLI/helper pair. This is not an exhaustive claim about
all storage. User+mount namespaces are available, but that alone does not establish
the required Codex sandbox, read roots, private MCP credentials or tool filtering.

## Compatible next step, not performed

Use a complete vendor-verified runtime/helper pair through a host-controlled
per-process executable path, without changing a shared runtime or disabling its
integrity guard. The matching vendor package was not available in the inspected
locations; acquiring or repairing it is separate host maintenance. Keep a dedicated
host-prepared CODEX_HOME with no legacy sandbox setting, explicit restrictive
permission profile, minimal agent environment, private scoped MCP transport and
secure existing authentication channel. Never copy real login or provider secrets
into this repository or the agent's readable roots.

Before implementing/enabling the real AppServer broker, run negative canaries on
its actual turn/tool route for outside reads, writes, environment and host/proc
credential visibility, MCP tool allowlists and network controls. Also verify the
server-derived identities and distinct reviewer/arbiter subjects. If any capability
cannot be enforced or authenticated, leave the existing default fail-closed. Do not
replace it with a pass-through broker or a new service/platform.

Official configuration references: [permission profiles](https://learn.chatgpt.com/docs/permissions)
and [App Server command execution](https://learn.chatgpt.com/docs/app-server#command-execution).
Profiles must not be mixed with legacy sandbox settings; a native command profile
is only one surface and does not itself constrain MCP transports or credentials.
