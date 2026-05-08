# Symphony Elixir — Claude Code variant

This directory contains a Claude Code adaptation of Symphony, derived from
[`SPEC.md`](../SPEC.md). The orchestrator, workspace manager, Linear adapter,
state machine, and observability layer come straight from the upstream
`openai/symphony` Elixir reference. The only swapped-out piece is the agent
runner: instead of driving a Codex app-server JSON-RPC session, this fork
spawns the Claude Code CLI in headless streaming mode.

> [!WARNING]
> This fork is preview software. It runs Claude Code without local sandboxing
> by default. Read the trust posture section before pointing it at a project
> you care about.

## What's different from upstream

| Layer | Upstream | This fork |
|-------|----------|-----------|
| Agent runner | `SymphonyElixir.Codex.AppServer` (JSON-RPC over stdio) | `SymphonyElixir.ClaudeCode.CLI` (`claude --print --output-format stream-json --verbose`) |
| Front matter section | `codex:` | `claude_code:` |
| Session continuation | Long-lived app-server thread | Per-turn subprocess + `claude --resume <session_id>` |
| Trust posture knob | `approval_policy` / `thread_sandbox` / `turn_sandbox_policy` | `permission_mode` (`default` / `acceptEdits` / `plan` / `bypassPermissions`) |
| Custom tool injection | `dynamic_tools` JSON-RPC slot, ships `linear_graphql` | Use Claude Code's MCP system (see "Tool integration" below) |

Everything else — workspace cwd safety, sanitized identifiers, RFC-spec polling,
exponential retry, stall detection, Phoenix LiveView dashboard, JSON API at
`/api/v1/*` — behaves the way the spec describes and the way upstream Symphony
shipped it.

## How it works

1. Polls Linear for candidate work.
2. Creates a per-issue workspace (sanitized identifier under
   `workspace.root`).
3. Builds a Liquid-rendered prompt from the workflow template.
4. Spawns the Claude Code CLI in the workspace as `claude --print
   --output-format stream-json --verbose --permission-mode <mode>`. The first
   turn lets Claude assign a session id; subsequent turns within the same
   worker resume it via `--resume`.
5. Streams stream-json events back to the orchestrator, which updates running
   state, token totals, and the dashboard.
6. If the Linear issue moves to a terminal state, Symphony stops the active
   agent for that issue and cleans up matching workspaces.

## Prerequisites

- [Claude Code CLI](https://claude.com/claude-code) on `PATH` (the binary the
  adapter spawns is the value of `claude_code.command`, defaulting to
  `claude`).
- A working Anthropic credential for that CLI — log in once with `claude` and
  the headless adapter will reuse the stored credentials.
- [mise](https://mise.jdx.dev/) for managing Erlang/Elixir versions.
- A Linear personal API key in `LINEAR_API_KEY`.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony symphony-cc
cd symphony-cc/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

A `--port` flag enables the Phoenix dashboard at `/` and the JSON API at
`/api/v1/*`. The dashboard surfaces running sessions, retry queue, token
totals, and the latest agent activity.

## Workflow configuration

`WORKFLOW.md` keeps the upstream YAML/Markdown shape; only the agent block
differs:

```yaml
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
claude_code:
  command: claude
  permission_mode: bypassPermissions
  # model: claude-opus-4-7
  extra_args: []
  turn_timeout_ms: 3600000
  read_timeout_ms: 30000
  stall_timeout_ms: 300000
---

You are working on a Linear issue {{ issue.identifier }}.
Title: {{ issue.title }}
{{ issue.description }}
```

`claude_code` field reference:

| Field | Default | Notes |
|-------|---------|-------|
| `command` | `claude` | Base CLI invocation. Symphony always appends `--print --output-format stream-json --verbose --permission-mode <mode>` (and `--resume <id>` on continuation turns). Pass extra global flags here or via `extra_args`. |
| `permission_mode` | `bypassPermissions` | One of `default`, `acceptEdits`, `plan`, `bypassPermissions`. The default matches the spec §10.5 high-trust profile and runs without per-action prompts. Tighten if you don't fully trust the workflow. |
| `model` | unset | Optional `--model` value. Leave unset to let `claude` pick. |
| `extra_args` | `[]` | List of additional argv items appended verbatim to every invocation. Useful for `--mcp-config path/to/mcp.json`. |
| `turn_timeout_ms` | `3_600_000` | Per-turn wall-clock cap; the adapter kills the subprocess and surfaces `:turn_timeout` after this. |
| `read_timeout_ms` | `30_000` | Reserved for synchronous read paths (currently unused by the streaming adapter; kept for parity with the spec config layer). |
| `stall_timeout_ms` | `300_000` | Spec §8.5 Part A: if no event arrives within this window, the orchestrator kills the worker and schedules a retry. Set `0` to disable stall detection. |

Other behaviour:

- `tracker.api_key` falls back to `LINEAR_API_KEY` when unset or when the value
  is the literal `$LINEAR_API_KEY`.
- Path values support `~` expansion. `workspace.root` accepts `$VAR` env
  references; `claude_code.command` stays a shell command string and any `$VAR`
  expansion happens in the launched shell.
- `agent.max_turns` caps how many back-to-back Claude Code turns one agent
  invocation will run while the Linear issue stays active.
- Hot reload: editing `WORKFLOW.md` while the service is running re-applies
  config to future ticks/dispatches without restart.

## Tool integration

Upstream Symphony shipped a `linear_graphql` dynamic tool the Codex
app-server could invoke directly. Claude Code's CLI doesn't have a per-session
"dynamic tool" slot — custom tools are exposed via MCP servers instead. The
recommended pattern:

1. Run a Linear MCP server (community implementations exist; or wrap the GraphQL
   API behind a small Anthropic-style MCP wrapper).
2. Register it globally with `claude mcp add ...`, or per-run via
   `claude_code.extra_args: ["--mcp-config", "/path/to/mcp.json"]`.
3. Reference the tool from your `WORKFLOW.md` prompt.

A first-party Linear MCP bridge for this fork is a TODO; until it lands, your
workflow needs to wire tooling itself.

## Trust posture

Symphony's filesystem invariants still hold: workspaces stay under
`workspace.root`, the agent's cwd must match the per-issue workspace, and
identifiers are sanitized to `[A-Za-z0-9._-]`. But Symphony is *not* a sandbox
for the agent's actions inside the workspace. With the default
`permission_mode: bypassPermissions`, Claude Code runs without the usual
per-tool prompts, which the spec §10.5 example calls out as the high-trust
profile.

If you don't fully trust the workflow contents, the issue body, or the
repository state being cloned into workspaces, harden the harness — for
instance:

- Use a stricter `permission_mode` (`acceptEdits` or `plan`).
- Run Symphony under a dedicated OS user with a chroot or namespace.
- Wrap `claude_code.command` in a sandboxing helper (`firejail`, `bwrap`,
  `nsjail`, container, VM).
- Restrict the network reachable from workspaces.

The CLI prints a startup banner that nags you about this until you pass the
acknowledgement flag. That nag is intentional.

## Project layout

- `lib/symphony_elixir/claude_code/cli.ex` — the Claude Code CLI adapter
- `lib/symphony_elixir/orchestrator.ex` — single-authority polling, dispatch,
  retries, reconciliation (spec §7, §8, §16)
- `lib/symphony_elixir/workspace.ex` — sanitized per-issue workspaces and
  hooks (spec §9)
- `lib/symphony_elixir/linear/` — Linear GraphQL adapter (spec §11)
- `lib/symphony_elixir/config/` — typed config layer (spec §6)
- `lib/symphony_elixir_web/` — Phoenix LiveView dashboard + JSON API
  (spec §13.7)
- `WORKFLOW.md` — sample workflow used for in-repo tests
- `test/` — ExUnit suite. The `claude_code_cli_test.exs` covers the new
  adapter; the upstream Codex JSON-RPC test was removed because the protocol
  no longer exists in this fork.

## Testing

```bash
mise exec -- mix test --no-cover
```

The live end-to-end test (`@moduletag :live_e2e`) is currently skipped: it was
authored against fake-Codex Docker workers driven over SSH, with `codex_*`
config keys this fork doesn't have. Re-enabling it needs a parallel rebuild
that drives `claude` over SSH.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
