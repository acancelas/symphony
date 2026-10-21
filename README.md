# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

The BOS fork publishes local workspaces atomically and confirms each clean candidate HEAD on its
non-forced remote issue branch before independent reviews or final evidence can begin. This makes
restart recovery depend on durable Git state rather than an X1 filesystem surviving intact.

Non-interactive BOS runs use the `never` approval policy. Symphony automatically accepts only
Codex's structured `mcp_tool_call` elicitations from the trusted local `bos-mcp` and
`codebase-memory` servers; unknown MCP elicitations still stop for operator input, and local shell
commands remain subject to the command policy and sandbox. This keeps evidence queries, indexed
code searches and durable review recording autonomous without turning arbitrary external MCP
prompts into an approval bypass.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).

## Governed host bootstrap (incomplete)

Issue 69 prepares an opt-in host broker with pinned native runtime, private BOS identity, original policy material and host-owned execution evidence. It remains disabled pending independent acceptance and live verification. Private host JSON carries explicit `runtime.policy_sources` path/SHA-256 pins and `runtime.policy_fallback_filenames`; no credentials belong in repository configuration. Global policy scope covers every worker operation. Explicitly pinned BOS host ancestors supplement native discovery; Git subtree policies apply only to their corresponding paths. See [the policy dossier](docs/issues/69/original-policy-material.md). No existing canary grants project gates or production authority.