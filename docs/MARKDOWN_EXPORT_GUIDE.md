# Building a Markdown Export Feature for Copilot LV

This guide covers everything you need to export sessions to markdown format.

## Quick Facts

- **Database**: SQLite at `copilot_lv.db`
- **Framework**: Ash Resource layer over AshSqlite
- **Agents Supported**: Copilot (3028 sessions), Claude (558), Codex (40), Gemini (22)
- **Total Events**: 976,277 across all sessions
- **File Resources**: See `lib/copilot_lv/sessions/*.ex` (6 resource files)

---

## Data Model Quick Reference

### Core Tables & Relationships

```
┌──────────────┐
│   sessions   │ (3,648 records)
│──────────────│
│ id (PK)      │ ← prefixed: gh_, claude_, codex_, gemini_
│ agent        │ ← copilot|claude|codex|gemini
│ source       │ ← live|imported
│ cwd          │ ← working directory
│ git_root     │ ← repo root
│ branch       │ ← git branch
│ model        │ ← model name
│ title        │ ← session title
│ summary      │ ← long description
│ started_at   │ ← timestamp
│ stopped_at   │ ← timestamp
│ event_count  │ ← total events
│ starred      │ ← boolean
└──────────────┘
       ↓
    ╔═════════════════════════════════════════════════╗
    ║
    ├─→ events (976,277 records)
    │     • event_type (user.message, assistant.message, tool.*, etc)
    │     • sequence (CRITICAL: sort by this, not timestamp)
    │     • data (JSON: schema-free, event-type specific)
    │     • timestamp
    │
    ├─→ usage_entries
    │     • model, input_tokens, output_tokens
    │     • cache_read_tokens, cache_write_tokens
    │     • cost, duration_ms
    │
    ├─→ session_artifacts
    │     • path, content, artifact_type
    │     • :plan, :workspace, :file, :session_db_dump, :codex_thread_meta
    │
    ├─→ checkpoints
    │     • number, title, filename, content
    │
    └─→ session_todos
          • todo_id, title, description, status
          • depends_on (array of todo_ids)
```

---

## Event Types by Agent

### Copilot (GenAI Standard)
```
user.message                    data: {content: "..."}
assistant.message               data: {content: "...", tokenCount: N}
tool.execution_start            data: {toolName: "read"|"write"|"shell", toolCallId, arguments}
tool.execution_complete         data: {toolCallId, success: bool, result: "...", error: "..."}
```

### Claude (Anthropic)
```
user                            data: {type: "text", text: "..."}
assistant                       data: {content: [{type: "text"/"tool_use", ...}]}
tool_use                        (in assistant.content)
tool_result                     data: {type: "tool_result", tool_use_id, content}
```

### Codex
```
user_message                    data: {content: "..."}
agent_message                   data: {content: "..."}
agent_reasoning                 data: {reasoning: "..."}
tool_call                       data: {tool_name, tool_input}
tool_result                     data: {tool_use_id, content, error}
```

### Gemini
```
user                            data: {content: {parts: [{text: "..."}]}}
assistant                       data: {content: {parts: [{text: "..."} or function_call]}}
tool_use                        (in assistant content)
tool_result                     data: {tool_result: {...}}
```

---

## Querying the Data

### Load Everything for a Session
```elixir
defmodule Export do
  alias CopilotLv.Sessions.{Session, Event, UsageEntry, Checkpoint, SessionArtifact, SessionTodo}

  def load_session(session_id) do
    session = 
      Session
      |> Ash.Query.filter(id == ^session_id)
      |> Ash.read_one!()

    events = 
      Event
      |> Ash.Query.for_read(:for_session, %{session_id: session_id})
      |> Ash.read!()
      |> Enum.sort_by(& &1.sequence)  # CRITICAL: sort by sequence

    usage = 
      UsageEntry
      |> Ash.Query.for_read(:for_session, %{session_id: session_id})
      |> Ash.read!()
      |> Enum.sort_by(& &1.timestamp)

    artifacts = 
      SessionArtifact
      |> Ash.Query.for_read(:for_session, %{session_id: session_id})
      |> Ash.read!()

    checkpoints = 
      Checkpoint
      |> Ash.Query.for_read(:for_session, %{session_id: session_id})
      |> Ash.read!()
      |> Enum.sort_by(& &1.number)

    todos = 
      SessionTodo
      |> Ash.Query.for_read(:for_session, %{session_id: session_id})
      |> Ash.read!()

    %{
      session: session,
      events: events,
      usage: usage,
      artifacts: artifacts,
      checkpoints: checkpoints,
      todos: todos
    }
  end
end
```

### List All Sessions
```elixir
sessions = 
  Session
  |> Ash.Query.for_read(:list_all)  # sorted by starred DESC, started_at DESC
  |> Ash.read!()
```

### Filter Sessions
```elixir
# By agent
claude_sessions = sessions |> Enum.filter(&(&1.agent == :claude))

# By hostname
my_sessions = sessions |> Enum.filter(&(&1.hostname == "beast"))

# By status
active = sessions |> Enum.filter(&(&1.status != :stopped))

# Imported only
imported = 
  Session
  |> Ash.Query.for_read(:imported)
  |> Ash.read!()
```

---

## Markdown Export Structure

### Recommended Sections

1. **YAML Front Matter** (for metadata)
   - session_id, agent, hostname
   - cwd, git_root, branch, model
   - started_at, stopped_at, duration
   - operation counts (files, commands, etc)

2. **Session Summary**
   - Title and description
   - Timeframe and environment
   - Event statistics

3. **Key Operations**
   - Files read (paths)
   - Files written/created (paths)
   - Commands executed (with results)
   - Searches performed

4. **Conversation Transcript**
   - Alternating user/assistant messages
   - Optionally include tool calls inline
   - Truncate long responses (configurable)

5. **Artifacts** (if any)
   - Plans, workspaces, files
   - Type and size info

6. **Todos** (if any)
   - Title, status, description
   - Dependency graph (if complex)

7. **Usage & Costs** (if tracked)
   - Total tokens (input/output)
   - Cost estimate
   - Cache hit rate (if Claude)

### Example Front Matter
```yaml
<!-- copilot-lv-session-export:v1 -->
---
session_id: gh_7a352a9c-8f1e-4015-b938-b5eba60199db
provider_id: 7a352a9c-8f1e-4015-b938-b5eba60199db
agent: copilot
hostname: beast
cwd: ~/projects/my_app
git_root: ~/projects
branch: main
model: claude-opus-4.6
started_at: 2026-02-20T09:31:41.277855Z
stopped_at: 2026-02-20T11:15:23.456789Z
duration_minutes: 104
event_count: 127
operation_counts:
  file_reads: 34
  file_writes: 12
  commands: 18
  searches: 5
  tool_calls: 127
token_summary:
  total_input: 45328
  total_output: 12847
  cache_read: 0
  cache_write: 0
  estimated_cost: "$0.82"
---
```

---

## Helper Functions to Extract Operations

### Parse Event Data Safely
```elixir
defp get_event_data(event) do
  case event.data do
    data when is_map(data) -> data
    data when is_binary(data) -> Jason.decode!(data)
    nil -> %{}
  end
end

defp get_in_event(event, keys, default \\ nil) do
  data = get_event_data(event)
  Kernel.get_in(data, List.wrap(keys)) || default
end
```

### Extract User Messages
```elixir
defp extract_user_messages(events) do
  events
  |> Enum.filter(&user_message?/1)
  |> Enum.map(fn e ->
    %{
      sequence: e.sequence,
      timestamp: e.timestamp,
      content: get_in_event(e, ["content"]),
      event_id: e.event_id
    }
  end)
end

defp user_message?(%{event_type: type}) do
  type in ["user.message", "user", "user_message"]
end
```

### Extract Assistant Responses
```elixir
defp extract_assistant_messages(events) do
  events
  |> Enum.filter(&assistant_message?/1)
  |> Enum.map(fn e ->
    content = get_in_event(e, ["content"])
    token_count = get_in_event(e, ["tokenCount"]) || get_in_event(e, ["tokens"])
    %{
      sequence: e.sequence,
      timestamp: e.timestamp,
      content: content,
      tokens: token_count,
      event_id: e.event_id
    }
  end)
end

defp assistant_message?(%{event_type: type}) do
  type in ["assistant.message", "assistant", "agent_message"]
end
```

### Extract Tool Calls
```elixir
defp extract_tool_calls(events) do
  events
  |> Enum.filter(&tool_call?/1)
  |> Enum.map(fn e ->
    %{
      sequence: e.sequence,
      timestamp: e.timestamp,
      tool_name: get_in_event(e, ["toolName"]),
      tool_id: get_in_event(e, ["toolCallId"]),
      arguments: get_in_event(e, ["arguments"]),
      event_type: e.event_type
    }
  end)
end

defp tool_call?(%{event_type: type}) do
  String.starts_with?(type, "tool.")
end
```

### Aggregate File Operations
```elixir
defp aggregate_files(events) do
  Enum.reduce(events, %{read: [], write: []}, fn event, acc ->
    case event.event_type do
      "tool.execution_complete" ->
        tool_name = get_in_event(event, ["toolName"])
        path = get_in_event(event, ["arguments", "path"])
        case tool_name do
          "read" when is_binary(path) ->
            %{acc | read: [path | acc.read]}
          "write" when is_binary(path) ->
            %{acc | write: [path | acc.write]}
          _ -> acc
        end
      _ -> acc
    end
  end)
end
```

---

## Existing Export Code to Reference

### Mix Task: `copilot.export`
**File**: `lib/mix/tasks/copilot.export.ex`

Exports to agent-native format:
- **Claude**: JSONL files in `.claude/projects/{encoded-cwd}/`
- **Codex**: JSONL in `.codex/sessions/{year}/{month}/{day}/`
- **Gemini**: JSON in `.gemini/tmp/{project-hash}/chats/`
- **Copilot**: JSONL in `.copilot/session-state/`

Shows how to:
- Load events for a session
- Reconstruct native format from events
- Handle different agent schemas

### Handoff Generator: `session_handoff.ex`
**File**: `lib/copilot_lv/session_handoff.ex`

Generates markdown with:
- YAML front matter
- Session summary
- File operations aggregation
- Transcript rendering
- Operation classification

**Extractor module** (`session_handoff/extractor.ex`):
- Parses event sequences per agent type
- Extracts prompts, assistant outputs, operations
- Handles tool call completion tracking

---

## Development Workflow

### 1. Create New Mix Task
```bash
touch lib/mix/tasks/copilot.markdown_export.ex
```

### 2. Structure
```elixir
defmodule Mix.Tasks.Copilot.MarkdownExport do
  use Mix.Task
  
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [...])
    Mix.Task.run("app.start")
    
    # Your logic here
    export_to_markdown(session_id, opts)
  end
end
```

### 3. Test
```bash
mix copilot.markdown_export --session gh_xxx --output ./exports/
```

---

## Important Quirks

1. **Sort Events by Sequence**: Not timestamp! Sequence is a guaranteed unique, ordered counter per session.

2. **Event Data is Schema-Free**: Parse `data` field carefully:
   - Might be JSON string: `Jason.decode!(event.data)`
   - Might be map already: `event.data`
   - Might have nested JSON: `get_in_event(event, ["arguments", "content"])`

3. **Agent Type Matters**: Event structure differs by agent:
   - Copilot: `tool.execution_*` events
   - Claude: `tool_use` blocks in assistant content
   - Codex: Custom reasoning events
   - Gemini: Google function_call format

4. **Session IDs are Prefixed**: 
   - Always contains `_` separator
   - First part (before `_`) identifies agent type
   - Use `Session.provider_id(id)` to extract raw provider ID

5. **Timestamps are Microsecond-Precision UTC**: Format as ISO 8601 when rendering: `DateTime.to_iso8601(timestamp)`

6. **Artifacts Have Type Enum**: Filter by type if needed:
   - `:plan` - planning documents
   - `:workspace` - workspace descriptions
   - `:file` - source files created/modified
   - `:session_db_dump` - database exports
   - `:codex_thread_meta` - Codex thread metadata

---

## Performance Tips

- Load events ordered by sequence immediately: `Enum.sort_by(&1.sequence)`
- Pre-aggregate operations instead of scanning events multiple times
- Use list comprehensions for filtering
- Batch write markdown files
- Cache decoded event.data in memory (events.data is often JSON strings)

---

## Testing Queries

```bash
# Interactive Elixir shell
iex -S mix

# List all sessions
Ash.read!(CopilotLv.Sessions.Session) |> length()

# Get one session
session = Ash.read_one!(CopilotLv.Sessions.Session)

# Load events
events = CopilotLv.Sessions.Event 
  |> Ash.Query.for_read(:for_session, %{session_id: session.id})
  |> Ash.read!()

# Check event types
events |> Enum.map(& &1.event_type) |> Enum.uniq()

# Parse event data
events |> Enum.at(0) |> Map.get(:data) |> inspect()
```

---

## SQLite Inspection (Without Elixir)

```bash
sqlite3 copilot_lv.db

# Stats
SELECT agent, COUNT(*) as count FROM sessions GROUP BY agent;

# Sample session
SELECT id, agent, cwd, title FROM sessions LIMIT 5;

# Events for one session
SELECT event_type, COUNT(*) FROM events 
  WHERE session_id = 'gh_...' 
  GROUP BY event_type;

# Event sequence check
SELECT sequence, event_type FROM events 
  WHERE session_id = 'gh_...' 
  ORDER BY sequence 
  LIMIT 10;
```

