# Copilot LV Data Model - Comprehensive Guide

## Overview
The **copilot_lv** Phoenix app uses **Ash Framework** with **SQLite** to persist AI coding agent sessions (from Copilot, Claude, Codex, and Gemini). The data model captures:
- **Sessions**: High-level metadata for coding sessions
- **Events**: Chronological sequence of conversation turns and tool executions
- **Supporting records**: Usage metrics, artifacts, todos, checkpoints

**Database Location**: `copilot_lv.db`

---

## Core Data Model

### 1. **Session** (Primary Entity)
**File**: `lib/copilot_lv/sessions/session.ex`  
**Table**: `sessions`  
**Purpose**: Top-level container for all activity from one agent session

#### Attributes:
| Field | Type | Notes |
|-------|------|-------|
| `id` | string (PK) | Prefixed ID: `{prefix}_{provider_id}` → `gh_7a352a9c...`, `claude_abc123...`, etc. |
| `agent` | atom | `:copilot`, `:claude`, `:codex`, `:gemini` |
| `source` | atom | `:live` (active) or `:imported` (from external import) |
| `cwd` | string | Current working directory |
| `git_root` | string | Repository root path |
| `branch` | string | Git branch name |
| `model` | string | Model used: `claude-opus-4.6`, etc. |
| `title` | string | User-provided or auto-generated session title |
| `summary` | string | Long-form summary of session activities |
| `hostname` | string | Machine name where session ran |
| `config_dir` | string | Agent config directory (e.g., `~/.copilot`) |
| `copilot_version` | string | Agent CLI version |
| `status` | atom | `:starting`, `:idle`, `:thinking`, `:tool_running`, `:stopped` |
| `starred` | boolean | User-marked favorite |
| `event_count` | integer | Total events in session |
| `started_at` | utc_datetime_usec | Session creation timestamp |
| `stopped_at` | utc_datetime_usec | Session end timestamp |
| `imported_at` | utc_datetime_usec | When imported to DB (if `:imported` source) |

#### ID Prefixes (Agent Types):
```
:copilot → "gh_"
:claude  → "claude_"
:codex   → "codex_"
:gemini  → "gemini_"
```

**Example ID**: `gh_7a352a9c-8f1e-4015-b938-b5eba60199db`

---

### 2. **Event** (Turns/Messages)
**File**: `lib/copilot_lv/sessions/event.ex`  
**Table**: `events`  
**Purpose**: Individual conversation turn, tool call, or system event

#### Attributes:
| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID v7 (PK) | Unique event identifier |
| `session_id` | string (FK) | Foreign key to sessions.id |
| `event_type` | string | **See event types below** |
| `event_id` | string | Original agent-assigned event ID (may be null) |
| `parent_event_id` | string | For nested events, links to parent |
| `sequence` | integer | **Critical**: Sequential order of events in session (sorted ASC) |
| `timestamp` | utc_datetime_usec | Event timestamp |
| `data` | map/JSON | **Schema-free**: Event-type-specific data |

#### Event Types:
**Copilot/GenAI Events:**
- `user.message` → User prompt (data: `{"content": "..."}`)
- `assistant.message` → Assistant response (data: `{"content": "...", "tokenCount": ...}`)
- `tool.execution_start` → Tool call initiated (data: `{"toolName": "...", "toolCallId": "...", "arguments": {...}}`)
- `tool.execution_complete` → Tool execution result (data: `{"toolCallId": "...", "success": bool, "result": "...", "error": "..."}`)

**Agent-Specific Events:**
- **Claude**: `user`, `assistant`, `tool_use`, `tool_result`
- **Codex**: `user_message`, `agent_message`, `agent_reasoning`, `tool_call`, `tool_result`
- **Gemini**: `user`, `assistant`, `tool_use`, `tool_result`

#### Relationship:
- **has_many**: One session has many events
- **Foreign Key**: events.session_id → sessions.id

**Unique Constraints**:
- `events_session_sequence_idx` on (session_id, sequence) — only one event per sequence
- `events_session_event_id_idx` on (session_id, event_id) where event_id IS NOT NULL

---

### 3. **UsageEntry** (Token/Cost Tracking)
**File**: `lib/copilot_lv/sessions/usage_entry.ex`  
**Table**: `usage_entries`  
**Purpose**: Track API tokens and costs per request

#### Attributes:
| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID v7 (PK) | |
| `session_id` | string (FK) | |
| `model` | string | Model name for this request |
| `input_tokens` | integer | Tokens sent to API |
| `output_tokens` | integer | Tokens returned by API |
| `cache_read_tokens` | integer | Anthropic/Claude cache hits |
| `cache_write_tokens` | integer | Anthropic/Claude cache writes |
| `cost` | float | Estimated USD cost |
| `initiator` | string | Which component initiated request |
| `duration_ms` | integer | API call latency |
| `timestamp` | utc_datetime_usec | Request timestamp |

---

### 4. **Checkpoint**
**File**: `lib/copilot_lv/sessions/checkpoint.ex`  
**Table**: `checkpoints`  
**Purpose**: Snapshot of file/state at numbered checkpoints

#### Attributes:
| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID v7 (PK) | |
| `session_id` | string (FK) | |
| `number` | integer | Checkpoint sequence (1, 2, 3...) |
| `title` | string | Human label |
| `filename` | string | Original filename |
| `content` | string | File content snapshot |

---

### 5. **SessionArtifact**
**File**: `lib/copilot_lv/sessions/session_artifact.ex`  
**Table**: `session_artifacts`  
**Purpose**: Store generated files, plans, and metadata

#### Attributes:
| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID v7 (PK) | |
| `session_id` | string (FK) | |
| `path` | string | File path or artifact key |
| `content` | string | Text content |
| `content_hash` | string | SHA hash for deduplication |
| `size` | integer | Bytes |
| `artifact_type` | atom | `:plan`, `:workspace`, `:file`, `:session_db_dump`, `:codex_thread_meta` |

**Unique**: (session_id, path) — only one artifact per path per session

---

### 6. **SessionTodo**
**File**: `lib/copilot_lv/sessions/session_todo.ex`  
**Table**: `session_todos`  
**Purpose**: Track open tasks/goals from session

#### Attributes:
| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID v7 (PK) | |
| `session_id` | string (FK) | |
| `todo_id` | string | Agent-assigned todo ID |
| `title` | string | Todo title (required) |
| `description` | string | Details |
| `status` | string | `pending`, `in_progress`, `done`, `blocked` |
| `depends_on` | array[string] | List of todo_ids this depends on (stored as JSON array) |

**Unique**: (session_id, todo_id) — only one todo per ID per session

---

## Database Schema (SQLite)

```sql
CREATE TABLE "sessions" (
  "id" TEXT PRIMARY KEY,
  "stopped_at" TEXT,
  "started_at" TEXT,
  "status" TEXT,
  "model" TEXT,
  "cwd" TEXT NOT NULL,
  "summary" TEXT,
  "git_root" TEXT,
  "branch" TEXT,
  "copilot_version" TEXT,
  "event_count" INTEGER,
  "source" TEXT,
  "imported_at" TEXT,
  "title" TEXT,
  "starred" INTEGER DEFAULT 0 NOT NULL,
  "hostname" TEXT,
  "agent" TEXT,
  "config_dir" TEXT
);

CREATE TABLE "events" (
  "id" TEXT PRIMARY KEY,
  "session_id" TEXT NOT NULL,
  "event_type" TEXT NOT NULL,
  "event_id" TEXT,
  "parent_event_id" TEXT,
  "sequence" INTEGER NOT NULL,
  "timestamp" TEXT,
  "data" TEXT DEFAULT '{}',
  FOREIGN KEY("session_id") REFERENCES "sessions"("id")
);

CREATE UNIQUE INDEX events_session_sequence_idx ON events(session_id, sequence);
CREATE UNIQUE INDEX events_session_event_id_idx ON events(session_id, event_id) WHERE event_id IS NOT NULL;

CREATE TABLE "usage_entries" (
  "id" TEXT PRIMARY KEY,
  "session_id" TEXT NOT NULL,
  "model" TEXT,
  "input_tokens" INTEGER,
  "output_tokens" INTEGER,
  "cache_read_tokens" INTEGER,
  "cache_write_tokens" INTEGER,
  "cost" NUMERIC,
  "initiator" TEXT,
  "duration_ms" INTEGER,
  "timestamp" TEXT,
  FOREIGN KEY("session_id") REFERENCES "sessions"("id")
);

CREATE TABLE "checkpoints" (
  "id" TEXT PRIMARY KEY,
  "session_id" TEXT NOT NULL,
  "number" INTEGER NOT NULL,
  "title" TEXT,
  "filename" TEXT,
  "content" TEXT,
  FOREIGN KEY("session_id") REFERENCES "sessions"("id")
);

CREATE TABLE "session_artifacts" (
  "id" TEXT PRIMARY KEY,
  "session_id" TEXT NOT NULL,
  "path" TEXT NOT NULL,
  "content" TEXT,
  "content_hash" TEXT NOT NULL,
  "size" INTEGER,
  "artifact_type" TEXT NOT NULL,
  FOREIGN KEY("session_id") REFERENCES "sessions"("id")
);

CREATE UNIQUE INDEX session_artifacts_unique_path_per_session_index 
  ON "session_artifacts" ("session_id", "path");

CREATE TABLE "session_todos" (
  "id" TEXT PRIMARY KEY,
  "session_id" TEXT NOT NULL,
  "todo_id" TEXT NOT NULL,
  "title" TEXT NOT NULL,
  "description" TEXT,
  "status" TEXT,
  "depends_on" TEXT DEFAULT '[]',
  FOREIGN KEY("session_id") REFERENCES "sessions"("id")
);

CREATE UNIQUE INDEX session_todos_unique_todo_per_session_index 
  ON "session_todos" ("session_id", "todo_id");
```

---

## Current Database Statistics

```
Total Sessions:  3,648
Total Events:    976,277

By Agent Type:
- Copilot:  3,028 sessions
- Claude:     558 sessions
- Codex:       40 sessions
- Gemini:      22 sessions
```

---

## Existing Export & Serialization Logic

### 1. **Export Mix Task** → Native Agent Format
**File**: `lib/mix/tasks/copilot.export.ex`

Exports DB sessions back to original agent format on disk for round-trip compatibility:

**Export Paths** (customizable via `--target`):
- **Claude**: `{target}/.claude/projects/{encoded-cwd}/{session-id}.jsonl`
- **Codex**: `{target}/.codex/sessions/{year}/{month}/{day}/rollout-{date}-{session-id}.jsonl`
- **Gemini**: `{target}/.gemini/tmp/{project-hash}/chats/session-{date}-{short-id}.json`
- **Copilot**: `{target}/.copilot/session-state/{session-id}/events.jsonl`

**Usage**:
```bash
mix copilot.export                    # All agents, default dir
mix copilot.export --agent claude     # Filter by agent
mix copilot.export --target ~/backup  # Custom output directory
mix copilot.export --dry-run          # Preview without writing
mix copilot.export --host beast       # Filter by hostname
```

---

### 2. **Session Handoff Markdown Generator**
**File**: `lib/copilot_lv/session_handoff.ex`

Generates human-readable handoff documents for agent takeover.

**Structure** (YAML front matter + Markdown):
```markdown
<!-- copilot-lv-session-handoff:v1 -->
---
session_id: gh_7a352a9c-8f1e-4015-b938-b5eba60199db
provider_id: 7a352a9c-8f1e-4015-b938-b5eba60199db
agent: copilot
hostname: beast
cwd: ~/projects/my_app
git_root: ~/projects
branch: main
model: claude-opus-4.6
started_at: 2026-02-20T09:31:41Z
event_count: 127
operation_counts:
  file_reads: 34
  file_writes: 12
  commands: 18
  searches: 5
---

## Resume Instructions
...

## Session Summary
...

## Outstanding Work
- open todos: ...
- incomplete operations: ...

## Files Read
...

## Files Written
...

## Commands Executed
...

## Transcript
...

## Continuation Notes
...
```

**Functions**:
- `generate(session_ref, opts)` → `{:ok, %{session, handoff, markdown}}`
- `takeover_prompt(handoff_url)` → Instructions for next agent

**Extractor Module** (`session_handoff/extractor.ex`):
Parses events based on agent type, extracting:
- User prompts
- Assistant outputs
- Tool calls (file reads, writes, command executions, searches)
- Pending operations
- Quota/rate-limit signals

---

## Asset Storage

### Artifacts (`session_artifacts` table):
- **Files created/modified**: Stored with `artifact_type: :file`
- **Plans**: `artifact_type: :plan`
- **Workspaces**: `artifact_type: :workspace`
- **Codex metadata**: `artifact_type: :codex_thread_meta`

### Event Data (`events.data` JSON field):
- **User messages**: `{"content": "...", ...}`
- **Assistant responses**: `{"content": "...", "tokenCount": N}`
- **Tool calls**: `{"toolName": "...", "arguments": {...}}`
- **Results**: `{"toolCallId": "...", "success": bool, "result": "..."}`

---

## Relationships Summary

```
Session
├── has_many Events (sequence order)
├── has_many UsageEntries (token tracking)
├── has_many Checkpoints (file snapshots)
├── has_many SessionArtifacts (generated content)
└── has_many SessionTodos (open tasks)

Event
└── belongs_to Session

UsageEntry
└── belongs_to Session

Checkpoint
└── belongs_to Session

SessionArtifact
└── belongs_to Session

SessionTodo
└── belongs_to Session
```

---

## Important Notes for Markdown Export Feature

### Key Metadata to Capture:
1. **Session Context**:
   - Agent type (copilot/claude/codex/gemini) — determines event schema
   - Timestamps (started_at, stopped_at)
   - Directory context (cwd, git_root, branch)
   - Model used

2. **Event Sequencing**:
   - Events MUST be sorted by `sequence` (not timestamp)
   - Each event has `event_type` (user.message, assistant.message, tool.*, etc.)
   - `data` field is JSON/map—may need parsing for some agent types

3. **Message Attribution**:
   - User messages: `event_type = "user.message"` (or agent-specific equiv)
   - Assistant responses: `event_type = "assistant.message"` (or equiv)
   - Separate user from assistant for clean markdown

4. **Tool/Operation Tracking**:
   - File operations: Look for `tool.execution_*` events with `toolName: ["read", "write", ...]`
   - Command execution: `toolName: "shell"` or similar
   - Search operations: `toolName: "search"`
   - Extract path, arguments, results from event.data

5. **Distinct per Agent**:
   - **Copilot**: Standard tool.execution_* schema
   - **Claude**: Anthropic message format, tool_use/tool_result blocks
   - **Codex**: Custom message + reasoning format
   - **Gemini**: Google format with content blocks

### Handoff Logic (Already Implemented):
- Detects quota/rate-limit signals (`last_visible_output` analysis)
- Extracts open todos (from session_todos)
- Finds incomplete operations
- Aggregates file reads/writes/commands/searches
- Truncates long outputs (configurable via opts)

---

## Ash Framework Integration

**Data Layer**: `AshSqlite.DataLayer`  
**Repository**: `CopilotLv.Repo`  
**Domain**: `CopilotLv.Sessions`

**All resources defined in**: `lib/copilot_lv/sessions/*.ex`

**Query examples**:
```elixir
# Read all sessions
Ash.read!(CopilotLv.Sessions.Session)

# Read sessions for handoff
Session |> Ash.Query.for_read(:list_all) |> Ash.read!()

# Read events for session
Event 
|> Ash.Query.for_read(:for_session, %{session_id: session_id})
|> Ash.read!()

# Filter by agent
sessions |> Enum.filter(&(&1.agent == :claude))
```

---

## Mix Tasks Available

**Directory**: `lib/mix/tasks/`

1. **`copilot.export`** — Export sessions back to native format (detailed above)
2. **`copilot.handoff`** — Generate handoff markdown for a session
3. **`copilot.import_remote`** — Import sessions from remote agent storage
4. **`copilot.sync`** — Sync sessions with agent data sources

---

## Building Your Markdown Export

### Recommended Approach:

1. **Load session + all related data**:
   ```elixir
   session = Ash.read_one!(Session)
   events = Ash.Query.for_read(:for_session, %{session_id: session.id}) |> Ash.read!()
   artifacts = Ash.Query.for_read(:for_session, %{session_id: session.id}) |> Ash.read!()
   todos = Ash.Query.for_read(:for_session, %{session_id: session.id}) |> Ash.read!()
   usage = Ash.Query.for_read(:for_session, %{session_id: session.id}) |> Ash.read!()
   ```

2. **Extract metadata from session**:
   - Title, summary, agent type, timestamps
   - Session context: cwd, git_root, branch, model

3. **Parse events sequentially**:
   - Sort by `sequence`
   - Switch on `event_type` to determine message type
   - Extract content from `data` map

4. **Build markdown sections**:
   - Front matter (YAML)
   - Session summary
   - Conversation transcript (user → assistant pairs)
   - Operations/tool calls
   - Artifacts
   - Todos

5. **Write to file**:
   - Filename: `{session_id}.md` or `{title}-{date}.md`
   - Include front matter for parsing

