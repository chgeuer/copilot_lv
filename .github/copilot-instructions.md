# Copilot Instructions

Phoenix LiveView web application for monitoring coding agent sessions.

## Server management

- **Start:** `just start`
- **Stop:** `just stop`
- **Restart:** `just stop` then `just start` — never kill processes directly
- **Status:** `just status`

## Key conventions

- Use `mix precommit` before committing
- Use `:req` (Req) for HTTP requests, never `:httpoison` or `:tesla`
- Use `<.icon name="hero-...">` for icons
- Use `<.input>` from core_components for form inputs
- Tailwind CSS v4 (no tailwind.config.js, uses `@import` / `@source` in app.css)
- DaisyUI for component styling

## Shared dependencies

The rich chat UI (session viewer, tool renderers, markdown) comes from `jido_tool_renderers` — a path dependency shared with `ex_paperclip`. JS hooks are imported from `jido_tool_renderers/session_viewer_hooks`.

See `AGENTS.md` for full guidelines.
