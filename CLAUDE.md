# CLAUDE.md

Phoenix LiveView web application for monitoring and interacting with coding agent sessions (Claude, Codex, Gemini, Copilot).

## Quick reference

- **Start server:** `just start`
- **Stop server:** `just stop`
- **Restart:** `just stop` then `just start` (always use this, never kill processes directly)
- **Check status:** `just status`
- **Run expression on node:** `just rpc '<expression>'`
- **Pre-commit checks:** `mix precommit`

## Key dependencies

- `jido_tool_renderers` — shared session viewer components (Rich chat UI, markdown rendering, tool call cards, JS hooks). Path dependency at `/home/chgeuer/github/chgeuer/jido_tool_renderers`.
- `jido_ghcopilot` — GitHub Copilot agent integration
- `jido_claude`, `jido_codex` — Claude/Codex agent adapters

## Architecture

- Sessions are watched by `CopilotLv.SessionWatcher` and managed by `CopilotLv.SessionServer`
- Events stream via PubSub to `SessionLive.Show` which uses `Jido.ToolRenderers.EventStream.Accumulator` for live rendering
- The rich chat UI (`Jido.ToolRenderers.SessionViewer.Rich`) is shared with `ex_paperclip`

See `AGENTS.md` for full guidelines.
