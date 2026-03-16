# ask_user: Interactive Tool Calls via External Tools

## Overview

When the GitHub Copilot CLI runs in server mode (`--server --stdio`), the built-in `ask_user` tool is not available — it only works in the interactive terminal UI. This document explains how we implement `ask_user` as an **external tool** using the Server protocol's native mechanism, so the LLM can ask users questions via a LiveView modal dialog.

## Background: Why Not MCP?

The Copilot CLI supports MCP (Model Context Protocol) servers via `--additional-mcp-config`, but this flag is **only processed in interactive/prompt mode**. In `--server` mode (which is what `jido_ghcopilot` uses), the MCP configuration is never read. This was confirmed by examining the minified CLI source:

- `startServerMode()` creates a `CLIServer` + `SessionManager` but never passes MCP config
- The MCP host initialization only happens in the interactive CLI entrypoint

## The External Tools Mechanism

The Server protocol supports **external tools** — tools defined by the client that the LLM can call. When the LLM invokes an external tool, the server sends a JSON-RPC **request** back to the client, reversing the usual request direction.

### Protocol Flow

```
Client (Elixir)                          Server (Copilot CLI)
     │                                        │
     │  session.create {tools: [...]}         │
     │───────────────────────────────────────▶│
     │                                        │  (LLM sees ask_user in tool list)
     │                                        │
     │  session.send {prompt: "..."}          │
     │───────────────────────────────────────▶│
     │                                        │  (LLM decides to call ask_user)
     │                                        │
     │  tool.call {toolName: "ask_user", ...} │
     │◀───────────────────────────────────────│  ← Server REQUEST to client
     │                                        │
     │  (show modal, wait for user)           │
     │                                        │
     │  {result: "Blue"}                      │
     │───────────────────────────────────────▶│  ← Client RESPONSE
     │                                        │
     │  session.event (assistant.message)     │
     │◀───────────────────────────────────────│  (LLM continues with answer)
```

### Key JSON-RPC Messages

**1. Registering the tool (in `session.create` params):**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "session.create",
  "params": {
    "model": "claude-sonnet-4.6",
    "tools": [{
      "name": "ask_user",
      "description": "Ask the user a question and wait for their response.",
      "parameters": {
        "type": "object",
        "properties": {
          "question": {"type": "string"},
          "choices": {"type": "array", "items": {"type": "string"}},
          "allow_freeform": {"type": "boolean", "default": true}
        },
        "required": ["question"]
      }
    }]
  }
}
```

**2. Server sends `tool.call` request to client:**

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "tool.call",
  "params": {
    "sessionId": "abc-123",
    "toolCallId": "tc-456",
    "toolName": "ask_user",
    "arguments": {
      "question": "What's your favorite color?",
      "choices": ["Blue", "Green", "Red"]
    }
  }
}
```

**3. Client responds with the user's answer:**

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "result": {"result": "Blue"}
}
```

## Architecture

### Component Overview

```
┌──────────────────────────────────────────────────────────┐
│  LiveView (show.ex)                                      │
│  ┌───────────────┐     ┌───────────────────────────┐     │
│  │ Chat UI       │     │ ask_user Modal            │     │
│  │               │     │ ┌───────────────────────┐ │     │
│  │               │     │ │ Question text         │ │     │
│  │               │     │ │ [Choice 1] [Choice 2] │ │     │
│  │               │     │ │ [___freeform input___]│ │     │
│  │               │     │ └───────────────────────┘ │     │
│  └───────────────┘     └───────────────────────────┘     │
└───────────┬────────────────────────┬─────────────────────┘
            │ PubSub                 │ AskUserBroker.respond()
            │ :ask_user_request      │
┌───────────▼────────────────────────▼────────────────────┐
│  SessionServer                                          │
│  - Defines @ask_user_tool                               │
│  - Handles {:server_tool_call, ...}                     │
│  - Spawns Task → broadcasts to LiveView                 │
│  -            → blocks on AskUserBroker.request()       │
│  -            → sends response via Connection           │
└───────────┬─────────────────────────────────────────────┘
            │
┌───────────▼─────────────────────────────────────────────┐
│  AskUserBroker (GenServer)                              │
│  - request(id, session, question, choices) → blocks     │
│  - respond(id, answer) → unblocks                       │
│  - Timeout after 5 minutes                              │
└─────────────────────────────────────────────────────────┘
            │
┌───────────▼─────────────────────────────────────────────┐
│  Connection (jido_ghcopilot)                            │
│  - Parses tool.call requests from server                │
│  - Broadcasts {:server_tool_call, ...} to subscribers   │
│  - respond_to_tool_call/3 sends JSON-RPC response       │
└───────────┬─────────────────────────────────────────────┘
            │ Erlang Port (stdin/stdout)
┌───────────▼─────────────────────────────────────────────┐
│  copilot_wrapper (Node.js)                              │
│  - Transparent JSON-RPC proxy                           │
│  - Forwards tool.call requests parent ← child           │
│  - Forwards responses parent → child                    │
└───────────┬─────────────────────────────────────────────┘
            │
┌───────────▼─────────────────────────────────────────────┐
│  Copilot CLI (--server --stdio)                         │
│  - Registers external tools from session.create         │
│  - Sends tool.call when LLM invokes external tool       │
│  - Resolves with result to continue LLM execution       │
└─────────────────────────────────────────────────────────┘
```

### Detailed Flow

1. **Session Creation** — `SessionServer` passes the `ask_user` tool definition in `session.create` (and `session.resume`). The Copilot CLI registers it as an external tool with an `externalToolDispatcher` callback.

2. **LLM Calls ask_user** — When the LLM decides to use `ask_user`, the CLI's `dispatchExternalTool` sends a `tool.call` JSON-RPC request through stdout.

3. **Request Routing** — The wrapper forwards it transparently. `Connection` parses it as a `{:request, ...}` (distinguished from responses by having both `id` and `method`), then broadcasts `{:server_tool_call, tool_call}` to subscriber processes.

4. **SessionServer Handling** — Receives `{:server_tool_call, %{tool_name: "ask_user"}}`, spawns a `Task` to avoid blocking the GenServer:
   - Broadcasts `{:ask_user_request, request}` via PubSub to the LiveView
   - Calls `AskUserBroker.request/4` which blocks until the user responds

5. **LiveView Modal** — Shows a modal with the question, choice buttons, and optional freeform input. User clicks a choice or types a response.

6. **Response Path** — LiveView calls `AskUserBroker.respond(request_id, answer)`, which unblocks the waiting Task. The Task then calls `Connection.respond_to_tool_call(conn, request_id, %{"result" => answer})`, sending the JSON-RPC response back through the Port.

7. **LLM Continues** — The CLI receives the tool result and the LLM continues its response, incorporating the user's answer.

## Key Files

### copilot_lv (Phoenix app)

| File | Purpose |
|------|---------|
| `lib/copilot_lv/ask_user_broker.ex` | GenServer managing pending requests, blocking/unblocking callers, timeouts |
| `lib/copilot_lv/session_server.ex` | Defines `@ask_user_tool`, handles `{:server_tool_call, ...}`, spawns response Tasks |
| `lib/copilot_lv_web/live/session_live/show.ex` | Modal UI component, event handlers for choices/freeform/dismiss |

### jido_ghcopilot (library)

| File | Purpose |
|------|---------|
| `lib/jido_ghcopilot/server/protocol.ex` | `tools` param in `session.create`, `parse/1` for server requests, `encode_response/2` |
| `lib/jido_ghcopilot/server/connection.ex` | `tool.call` handling, `{:server_tool_call, ...}` broadcast, `respond_to_tool_call/3` |

## Adding More External Tools

To add another external tool (e.g. `confirm_action`):

1. **Define the tool** in `SessionServer`:

```elixir
@confirm_tool %{
  name: "confirm_action",
  description: "Ask the user to confirm a destructive action.",
  parameters: %{
    type: "object",
    properties: %{
      action: %{type: "string", description: "Description of the action to confirm"}
    },
    required: ["action"]
  }
}
```

2. **Add it to the tools list** in `session_opts`:

```elixir
session_opts = %{
  model: state.model,
  tools: [@ask_user_tool, @confirm_tool]
}
```

3. **Handle the tool call** in SessionServer:

```elixir
def handle_info({:server_tool_call, %{tool_name: "confirm_action"} = tool_call}, state) do
  # Similar pattern to ask_user — broadcast to LiveView, wait for response
end
```

4. **Add UI** in the LiveView for the new tool's interaction pattern.

## Caveats

- **Model switching**: When the wrapper performs a model switch (destroy + recreate session), external tools are re-registered automatically since both `session.create` and `session.resume` pass the `tools` parameter.
- **Timeout**: Requests time out after 5 minutes via `AskUserBroker`. The LLM receives a timeout error and can retry or proceed without the answer.
- **Session resume**: External tools are passed on `session.resume` as well, so they survive session restarts.
