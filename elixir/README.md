# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

> **BHORC fork notes.** This fork extends upstream Symphony with two adapters
> registered in addition to the originals: a Plane tracker adapter
> (`tracker.kind: plane`) and a Claude Code agent adapter
> (`agent.kind: claude_code`). It also adds per-issue agent routing via labels
> (`agent.routing: by_label`) so different issues can be handled by different
> agents in the same workspace. See `Trackers` and `Agents` below.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Pick a tracker and authenticate:
   - **Linear** — get a personal token via Settings → Security & access → Personal API keys, and
     set it as `LINEAR_API_KEY`.
   - **Plane** — create an API token via Workspace settings → API tokens, and set it as
     `PLANE_API_KEY`. See `.env.example` at the repo root for the full list of variables this
     fork reads.
3. Copy this directory's `WORKFLOW.md` to your repo and customize it for your project.
   - For Linear, get the project slug from the project URL.
   - For Plane, you need both the workspace slug (from the workspace URL) and the project UUID
     (`mcp__plane__list_projects` or `https://api.plane.so/api/v1/workspaces/<slug>/projects/`).
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows. There is no equivalent dynamic tool for
     Plane in this fork; use `curl` from the agent shell or, with Claude Code, the `mcp__plane__*`
     tools.
5. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example (Linear + Codex, upstream defaults):

```md
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
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Plane + per-issue agent routing example (BHORC fork):

```md
---
tracker:
  kind: plane
  api_key: $PLANE_API_KEY
  workspace_slug: my-workspace
  project_slug: 9f54069d-079b-4f3e-bed6-5c461298a64f
  active_states: ["Ready for dev"]
  terminal_states: ["Done", "Cancelled"]
workspace:
  root: ~/symphony-workspaces/my-project
hooks:
  after_create: |
    git clone --depth 1 git@github.com:my-org/my-project.git .
    npm install
agent:
  kind: claude_code      # default agent
  routing: by_label      # tickets with `agent:codex` label override the default
  max_turns: 8
codex:
  command: codex app-server
claude_code:
  command: claude
  permission_mode: acceptEdits
  max_turns_per_invocation: 30
---

You are working on issue {{ issue.identifier }}.

Title: {{ issue.title }}
Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` (kind: linear) or `PLANE_API_KEY` (kind: plane) when
  the value is unset or written as `$LINEAR_API_KEY` / `$PLANE_API_KEY`. Same fallback applies to
  `tracker.assignee` via `LINEAR_ASSIGNEE` / `PLANE_ASSIGNEE`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Trackers

Symphony selects a tracker adapter based on `tracker.kind` in `WORKFLOW.md`.
Built-in kinds in this fork:

| `tracker.kind` | Module | Notes |
|---|---|---|
| `linear` | `SymphonyElixir.Linear.Adapter` | Upstream default. GraphQL against `https://api.linear.app/graphql`. |
| `plane` | `SymphonyElixir.Plane.Adapter` | REST against `https://api.plane.so` (configurable via `tracker.endpoint` for self-hosted Plane). Plane requires both `workspace_slug` and `project_slug` (the latter is the project UUID). The public REST API does not honor server-side state filtering on the issue list endpoint, so the adapter paginates fully and filters by state ID client-side. |
| `memory` | `SymphonyElixir.Tracker.Memory` | In-memory fixture for tests and dry runs. |

## Agents

Symphony selects an agent adapter based on `agent.kind` plus optional
per-issue routing via `agent.routing`. Built-in kinds in this fork:

| `agent.kind` | Module | Notes |
|---|---|---|
| `codex` | `SymphonyElixir.Codex.AppServer` | Upstream default. JSON-RPC over stdio against the Codex app-server protocol. Supports remote workers via SSH. |
| `claude_code` | `SymphonyElixir.ClaudeCode.AppServer` | Spawns `claude -p <prompt> --output-format stream-json --verbose` and parses each JSONL event. Local-only (no SSH worker support). Authentication is delegated to the host (`claude login`), no API key required. |

### Routing

`agent.routing: fixed` (default) always uses `agent.kind`.

`agent.routing: by_label` looks at the issue's labels for the first one
matching the case-insensitive pattern `agent:<kind>` (e.g. `agent:codex`,
`agent:claude_code`) and uses that adapter. If no `agent:*` label is present,
it falls back to `agent.kind`.

### Registering custom agent adapters

To add a new adapter (Gemini, GLM, custom in-house tool, etc.), implement the
`SymphonyElixir.Agent` behaviour in your own module and register it via
application env:

```elixir
Application.put_env(:symphony_elixir, :agent_adapters, %{
  "gemini" => MyApp.Gemini.AppServer
})
```

This map is merged on top of `SymphonyElixir.Agent.builtin_adapters/0`, so
runtime overrides win on key collision. After registration the new kind is
selectable via `agent.kind` or via an `agent:gemini` label.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
