# Markdown Export Feature - Developer Reference

## What You Now Have

I've created comprehensive documentation for building a markdown export feature for the copilot_lv Phoenix/Ash SQLite app. Here's what's included:

### Documentation Files

1. **`DATA_MODEL.md`** (527 lines, 16 KB)
   - Complete data model overview
   - All 6 Ash resources with full attributes and relationships
   - Database schema (CREATE TABLE statements)
   - Current statistics (3,648 sessions, 976,277 events)
   - Existing export/serialization logic
   - Markdown handoff document generator reference

2. **`MARKDOWN_EXPORT_GUIDE.md`** (512 lines, 13 KB)
   - Quick reference for building export features
   - Event types by agent (Copilot/Claude/Codex/Gemini)
   - Code examples for querying data
   - Helper functions for extracting operations
   - Markdown structure recommendations
   - Development workflow
   - Performance tips and testing queries

---

## Key Findings

### Data Model (6 Tables)

```
Session (3,648)
├─ Events (976,277) — sorted by SEQUENCE, not timestamp
├─ UsageEntries (token/cost tracking)
├─ Checkpoints (file snapshots)
├─ SessionArtifacts (plans, workspaces, files)
└─ SessionTodos (open tasks)
```

### Agent Distribution
- **Copilot**: 3,028 sessions (83%)
- **Claude**: 558 sessions (15%)
- **Codex**: 40 sessions (1%)
- **Gemini**: 22 sessions (0.6%)

### Critical Fields for Markdown Export

1. **Session Metadata**
   - `agent` — determines event schema interpretation
   - `source` — `:live` or `:imported`
   - `cwd`, `git_root`, `branch`, `model` — context
   - `started_at`, `stopped_at` — timeframe
   - `title`, `summary` — description

2. **Events (THE CORE)**
   - `sequence` — MUST sort by this (0, 1, 2, ...), NOT timestamp
   - `event_type` — differs by agent type
   - `data` — JSON payload (schema-free, may need parsing)
   - Links via `session_id` foreign key

3. **Event Types**
   - **Copilot**: `user.message`, `assistant.message`, `tool.execution_*`
   - **Claude**: `user`, `assistant`, `tool_use`, `tool_result`
   - **Codex**: `user_message`, `agent_message`, `agent_reasoning`, `tool_call`
   - **Gemini**: `user`, `assistant`, `tool_use`, `tool_result`

---

## How to Use These Docs

### If you're building markdown export:

1. **Start with**: `MARKDOWN_EXPORT_GUIDE.md` → "Data Model Quick Reference" section
2. **For details**: `DATA_MODEL.md` → Full schema and relationships
3. **For queries**: `MARKDOWN_EXPORT_GUIDE.md` → "Querying the Data" section
4. **For examples**: Look at existing code in:
   - `lib/mix/tasks/copilot.export.ex` — exports to native format
   - `lib/copilot_lv/session_handoff.ex` — generates markdown with YAML front matter
   - `lib/copilot_lv/session_handoff/extractor.ex` — parses events by agent type

### If you're just exploring the data:

Use SQL directly:
```bash
sqlite3 copilot_lv.db

# See schema
.schema

# List sessions
SELECT id, agent, cwd, title FROM sessions LIMIT 10;

# Count by agent
SELECT agent, COUNT(*) FROM sessions GROUP BY agent;

# Events for one session
SELECT event_type, COUNT(*) FROM events 
  WHERE session_id = 'gh_xxx' GROUP BY event_type;
```

---

## Directory Structure (Relevant Files)

```
lib/copilot_lv/sessions/
├─ session.ex              — Session resource (primary entity)
├─ event.ex                — Event resource (turns/messages)
├─ usage_entry.ex          — Token/cost tracking
├─ checkpoint.ex           — File snapshots
├─ session_artifact.ex     — Generated content
├─ session_todo.ex         — Open tasks
└─ sessions.ex             — Domain definition

lib/mix/tasks/
├─ copilot.export.ex       — ⭐ Export to native format
├─ copilot.handoff.ex      — Generate handoff markdown
├─ copilot.import_remote.ex — Import from external storage
└─ copilot.sync.ex         — Sync with agent sources

lib/copilot_lv/
├─ session_handoff.ex      — ⭐ Markdown generation logic
└─ session_handoff/
   └─ extractor.ex         — Event parsing per agent type

Database:
└─ copilot_lv.db           — SQLite (3,648 sessions)
```

---

## Next Steps for Markdown Export

### Option 1: Create a New Mix Task
```bash
mix ecto.gen.task copilot.markdown_export
```

Template structure (see `MARKDOWN_EXPORT_GUIDE.md` → "Development Workflow"):
```elixir
defmodule Mix.Tasks.Copilot.MarkdownExport do
  use Mix.Task

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [
      session: :string,
      output: :string,
      agent: :string
    ])
    
    Mix.Task.run("app.start")
    
    # Implementation
  end
end
```

### Option 2: Add to Existing Handoff Module
Extend `lib/copilot_lv/session_handoff.ex` with:
- `to_markdown/2` — render as markdown document
- `write_file/3` — save to disk with front matter

---

## Quick Command Reference

### IEx Shell Queries
```elixir
# Get all sessions
sessions = Ash.read!(CopilotLv.Sessions.Session)

# Load a specific session with all data
session = Ash.read_one!(CopilotLv.Sessions.Session)
events = CopilotLv.Sessions.Event 
  |> Ash.Query.for_session(%{session_id: session.id})
  |> Ash.read!()
  |> Enum.sort_by(& &1.sequence)

# Filter by agent
claude_sessions = Ash.read!(CopilotLv.Sessions.Session)
  |> Enum.filter(&(&1.agent == :claude))

# Get event summary
events |> Enum.map(& &1.event_type) |> Enum.uniq()
```

### SQLite Queries
```sql
-- Session stats
SELECT agent, COUNT(*) as count FROM sessions GROUP BY agent;

-- Session details
SELECT id, agent, cwd, started_at, stopped_at FROM sessions 
  WHERE agent = 'copilot' LIMIT 5;

-- Event types in a session
SELECT DISTINCT event_type FROM events 
  WHERE session_id = 'gh_xxx' ORDER BY event_type;

-- Event count by type
SELECT event_type, COUNT(*) FROM events 
  WHERE session_id = 'gh_xxx' GROUP BY event_type;
```

---

## Important Implementation Notes

1. **⚠️ Sort Events by SEQUENCE**
   - Not by timestamp!
   - Sequence is the guaranteed order (0, 1, 2, ...)
   - Use: `Enum.sort_by(events, & &1.sequence)`

2. **Event Data Parsing**
   - `event.data` might be JSON string or map
   - Check before parsing: `is_binary/is_map`
   - Use helper: `Jason.decode!` if string

3. **Agent-Specific Logic**
   - Each agent stores events differently
   - Switch on `session.agent` to parse event types
   - See `session_handoff/extractor.ex` for agent-specific parsing

4. **Session ID Format**
   - Prefixed: `{prefix}_{provider_id}`
   - Extract provider ID: `Session.provider_id(session_id)`
   - Extract agent: `Session.agent_from_id(session_id)`

5. **Relationships are Lazy**
   - Must load explicitly via Ash Query
   - Use `:for_session` action for filtering by session_id
   - Relationships: `has_many` (session) and `belongs_to` (child)

---

## Files to Reference

### For Event Parsing
- `lib/copilot_lv/session_handoff/extractor.ex` (620 lines)
  - `extract/2` — main entry point
  - `extract_copilot/2`, `extract_claude/2`, etc.
  - Helper functions for parsing each agent type

### For Markdown Generation
- `lib/copilot_lv/session_handoff.ex` (874 lines)
  - `render_markdown/2` — main renderer
  - Front matter rendering
  - Section rendering (summary, transcript, operations, etc.)
  - YAML escaping helpers

### For Export Format Reference
- `lib/mix/tasks/copilot.export.ex` (245 lines)
  - Shows how to reconstruct native formats
  - File path construction per agent
  - Event-to-JSON serialization

---

## Resources in This Package

| File | Lines | Purpose |
|------|-------|---------|
| DATA_MODEL.md | 527 | Complete reference (tables, fields, relationships) |
| MARKDOWN_EXPORT_GUIDE.md | 512 | Practical guide (queries, examples, structure) |
| EXPORT_FEATURE_README.md | This file | Overview and next steps |

---

## Questions to Answer While Building

1. **What markdown sections do you want?**
   - Conversation transcript only?
   - Also include operations (files, commands)?
   - Artifacts and todos?

2. **How to handle different agents?**
   - Single unified format?
   - Agent-specific sections?
   - Or normalize everything to standard format?

3. **File naming and output?**
   - `{session_id}.md`?
   - `{title}-{date}.md`?
   - Into directory or single file?

4. **Truncation strategy?**
   - Limit response length?
   - Include full transcript or summary?
   - Compress tool outputs?

5. **Front matter content?**
   - YAML metadata?
   - Comments with source info?
   - Query hints for reparsing?

---

**Good luck with your markdown export feature! 🚀**
