# Original policy material — offline bootstrap, 2026-10-16

The existing PromptBuilder now prepares complete original policy texts, their source paths, scopes, SHA-256 pins and a canonical manifest digest. This preparatory function is not yet wired into the primary broker and changes no installed host configuration.

Global discovery selects AGENTS.override.md, otherwise AGENTS.md. Host ancestor policies require an explicit exact inventory of path/hash pins. Repository policies come from regular Git blobs at the exact candidate SHA; the host also requires identical regular, single-link working-tree files. Within each repository directory, override, AGENTS.md and explicitly configured fallback names have precedence, skipping empty blobs. All committed nested policy scopes are included with scope labels and original bytes; no summary or size truncation is used. Untracked policy files in the implementation source scopes fail closed. Missing global guidance, missing pins, additional host ancestor policies, changed files and symlink aliases fail closed.

Official discovery reference: https://learn.chatgpt.com/docs/agent-configuration/agents-md . Host ancestor inclusion and all nested scoped material are explicit BOS requirements beyond native cwd-only discovery.

## Actual native model calibration

Root246 authorized one isolated synthetic fixture model turn during provider cooldown. It made no BOS API calls, claims, admissions or project source changes. Native thread `01a14367-c842-7721-a64e-4edd35486848` used the existing primary recipe with network disabled, four fixture-only writable roots and inert providers. The actual thread/start response and five original policy sources were fsynced to a private pre-model record before turn/start. Automatic project discovery used project_doc_max_bytes=0; the original global and host/repository policies were injected without summaries.

Private evidence remains under the existing runtime probe directory `implementation-1792132235959954`:

- `premodel-scope.json`: SHA-256 `171ae0f5b4405da0211ce7911c9acb90f08c121ef306486256d32d7340ce6d3d`.
- Original `report.json`: SHA-256 `828daffea242504a734fab11c1c5cda770ef1c42afb3fd13ce0b927076df0107`, unchanged, its aggregate flag is false because whole-output JSON parsing rejected one startup shell warning before the result.
- Append-only `parser-evaluation.json`: SHA-256 `19ed933061dd30cbbdd4b34565904e5208d412abe0d8768b88800d24738aaf09`. It strips only the exact recorded warning prefix, then verifies the original command output against every current required denial and both positives. All current recipe checks passed; process reaped.

Actual native usage: input 38,004; cached input 28,288; uncached input 9,716. Cost unknown, never zero. Policy manifest digest: `658c4888f320daa0ec14aaef0f9eda4b130ab327b1135d35ed4d07d47eb7f976`; original policy prompt digest `4dd47da2e771a076022f03560c33d41d15401e3775b2db8717204c583f15cf51`.

This demonstrates a synthetic native command with the current recipe and supplied originals. It does not approve the injection design, certify all alternate policy filenames, certify QA loopback, grant project gates, activate a worker, change runtime pins or authorize production. Independent review, broker wiring and exact final candidate QA remain pending. The existing filesystem recipe still needs assessment of alternate policy filename protection before any broader primary certification.