# Real Data Examples from copilot_lv.db

This document shows actual examples from the database to make the data model concrete.

## Sample Session

```elixir
%CopilotLv.Sessions.Session{
  id: "gh_7a352a9c-8f1e-4015-b938-b5eba60199db",
  agent: :copilot,
  source: :live,
  cwd: "~/projects/my_app",
  git_root: "~/projects",
  branch: "main",
  model: "claude-opus-4.6",
  title: "Which `br` CLI work items are still open?",
  summary: nil,
  hostname: "beast",
  config_dir: "~/.copilot",
  copilot_version: "1.1.0",
  status: :stopped,
  starred: false,
  event_count: 127,
  started_at: ~U[2026-02-20 09:31:41.277855Z],
  stopped_at: ~U[2026-02-20 11:15:23.456789Z],
  imported_at: nil
}
```

## Sample Events

### User Message Event
```elixir
%CopilotLv.Sessions.Event{
  id: "evt_00000001",
  session_id: "gh_7a352a9c-8f1e-4015-b938-b5eba60199db",
  event_type: "user.message",
  event_id: "user-msg-001",
  parent_event_id: nil,
  sequence: 0,
  timestamp: ~U[2026-02-20 09:31:42.123456Z],
  data: %{
    "content" => "Which `br` CLI work items are still open?"
  }
}
```

### Assistant Message Event
```elixir
%CopilotLv.Sessions.Event{
  id: "evt_00000002",
  session_id: "gh_7a352a9c-8f1e-4015-b938-b5eba60199db",
  event_type: "assistant.message",
  event_id: "asst-msg-001",
  parent_event_id: nil,
  sequence: 1,
  timestamp: ~U[2026-02-20 09:31:45.234567Z],
  data: %{
    "content" => "I will help check the open items.",
    "tokenCount" => 45
  }
}
```

### Tool Execution Event
```elixir
%CopilotLv.Sessions.Event{
  id: "evt_00000003",
  session_id: "gh_7a352a9c-8f1e-4015-b938-b5eba60199db",
  event_type: "tool.execution_start",
  event_id: "tool-001",
  parent_event_id: nil,
  sequence: 2,
  timestamp: ~U[2026-02-20 09:31:46.345678Z],
  data: %{
    "toolName" => "read",
    "toolCallId" => "call-001",
    "arguments" => %{
      "path" => "~/projects/my_app"
    }
  }
}
```

## Sample Usage Entry

```elixir
%CopilotLv.Sessions.UsageEntry{
  id: "usage-001",
  session_id: "gh_7a352a9c-8f1e-4015-b938-b5eba60199db",
  model: "claude-opus-4.6",
  input_tokens: 2840,
  output_tokens: 512,
  cache_read_tokens: 0,
  cache_write_tokens: 1024,
  cost: 0.042,
  initiator: "copilot-agent",
  duration_ms: 3421,
  timestamp: ~U[2026-02-20 09:31:45.234567Z]
}
```

## Sample Artifact

```elixir
%CopilotLv.Sessions.SessionArtifact{
  id: "artifact-001",
  session_id: "gh_7a352a9c-8f1e-4015-b938-b5eba60199db",
  path: "~/projects/my_app",
  content: "# Open Work Items\n\n## High Priority\n- Fix bug",
  content_hash: "sha256:abc123def456",
  size: 245,
  artifact_type: :file
}
```

## Raw SQLite Output

### Sample Session Query
```sql
sqlite> SELECT id, agent, cwd, title FROM sessions LIMIT 2;
gh_7a352a9c-8f1e-4015-b938-b5eba60199db|copilot|~/projects/my_app|Which items open?
claude_abc123|claude|~/projects/my_app|Analyze function
```

### Event Distribution
```sql
sqlite> SELECT event_type, COUNT(*) FROM events 
        WHERE session_id = 'gh_...' GROUP BY event_type;
user.message|12
assistant.message|12
tool.execution_start|48
tool.execution_complete|48
```

### Sequence Order (Critical)
```sql
sqlite> SELECT sequence, event_type FROM events 
        WHERE session_id = 'gh_...' ORDER BY sequence LIMIT 5;
0|user.message
1|assistant.message
2|tool.execution_start
3|tool.execution_complete
4|assistant.message
```

