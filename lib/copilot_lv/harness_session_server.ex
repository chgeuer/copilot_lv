defmodule CopilotLv.HarnessSessionServer do
  @moduledoc """
  GenServer managing a live session for any Jido.Harness.Adapter agent
  (Claude, Codex, Gemini).

  Calls `Adapter.run/2` which returns a stream of `Jido.Harness.Event` structs,
  consumes the stream in a background Task, and translates each event into the
  copilot-native vocabulary so the existing LiveView pipeline (Accumulator,
  EventStream, PubSub) works unchanged.
  """
  use GenServer
  require Logger

  alias CopilotLv.Sessions.{Event, UsageEntry, Session}
  alias Jido.Harness.RunRequest
  alias Phoenix.PubSub

  @adapters %{
    claude: Jido.Claude.Adapter,
    codex: Jido.Codex.Adapter,
    gemini: Jido.Gemini.Adapter
  }

  defstruct [
    :id,
    :agent,
    :adapter,
    :model,
    :cwd,
    :stream_task,
    :ask_user_mcp_server_name,
    permissions: %{},
    status: :idle,
    usage: [],
    event_count: 0,
    sequence: 0
  ]

  # ── Public API ──

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def send_prompt(id, prompt, opts \\ []) do
    GenServer.call(via(id), {:send_prompt, prompt, opts}, :infinity)
  end

  def get_state(id) do
    GenServer.call(via(id), :get_state)
  end

  def stop(id) do
    GenServer.stop(via(id), :normal)
  end

  defp via(id), do: {:via, Registry, {CopilotLv.SessionRegistry.Registry, id}}

  # ── Callbacks ──

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    agent = Keyword.fetch!(opts, :agent)
    model = Keyword.get(opts, :model)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    permissions = Keyword.get(opts, :permissions, %{})

    adapter = Map.fetch!(@adapters, agent)

    state = %__MODULE__{
      id: id,
      agent: agent,
      adapter: adapter,
      model: model,
      cwd: cwd,
      permissions: permissions,
      status: :idle
    }

    persist_status(state)
    broadcast(state, {:session_status, :idle})

    {:ok, state}
  end

  @impl true
  def handle_call({:send_prompt, _prompt, _opts}, _from, %{status: status} = state)
      when status not in [:idle] do
    {:reply, {:error, :not_idle}, state}
  end

  def handle_call({:send_prompt, prompt, opts}, _from, state) do
    state = %{state | status: :thinking, sequence: state.sequence + 1}
    broadcast(state, {:session_status, :thinking})

    # Persist user message
    user_event = %{
      id: "user-#{System.unique_integer([:positive])}",
      type: "user.message",
      data: %{"content" => prompt},
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    persist_event(state, user_event)
    broadcast(state, {:session_event, user_event})

    # Set up ask_user MCP tool for Claude sessions
    {state, agent_metadata} = setup_ask_user_and_metadata(state, opts)

    # Build RunRequest for the adapter
    metadata_key = to_string(state.agent)

    request =
      RunRequest.new!(%{
        prompt: prompt,
        cwd: state.cwd,
        model: state.model,
        metadata: %{metadata_key => agent_metadata}
      })

    # Start streaming in a background task
    server = self()

    task =
      Task.async(fn ->
        case state.adapter.run(request, Keyword.merge(opts, agent_run_opts(state))) do
          {:ok, stream} ->
            stream
            |> Stream.each(fn event ->
              send(server, {:harness_event, event})
            end)
            |> Stream.run()

            send(server, :stream_done)

          {:error, reason} ->
            send(server, {:stream_error, reason})
        end
      end)

    {:reply, :ok, %{state | stream_task: task}}
  end

  def handle_call(:get_state, _from, state) do
    info = %{
      id: state.id,
      agent: state.agent,
      model: state.model,
      cwd: state.cwd,
      status: state.status,
      event_count: state.event_count,
      usage: Enum.reverse(state.usage)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_info(
        {:harness_event, %Jido.Harness.Event{type: :ask_user} = event},
        state
      ) do
    handle_codex_user_input_request(state, event)
  end

  def handle_info({:harness_event, %Jido.Harness.Event{} = event}, state) do
    {type, data} = translate_event(event)

    if type in ["user.message"] do
      {:noreply, state}
    else
      state = %{state | event_count: state.event_count + 1, sequence: state.sequence + 1}

      # Build event map in copilot format, preserving raw adapter event for round-trip
      raw_data = sanitize_raw_event(event)

      event_map = %{
        id: (event.raw && Map.get(event.raw, :id)) || "ev-#{System.unique_integer([:positive])}",
        type: type,
        data: data,
        raw_data: raw_data,
        timestamp: event.timestamp || DateTime.utc_now() |> DateTime.to_iso8601()
      }

      persist_event(state, event_map)

      # Track usage
      state =
        if type == "assistant.usage" do
          entry = %{
            model: data["model"],
            input_tokens: data["inputTokens"] || 0,
            output_tokens: data["outputTokens"] || 0,
            cache_read_tokens: data["cacheReadTokens"] || 0,
            cache_write_tokens: data["cacheWriteTokens"] || 0,
            cost: data["cost"],
            initiator: data["initiator"],
            duration_ms: data["duration"]
          }

          persist_usage(state, entry)
          %{state | usage: [entry | state.usage]}
        else
          state
        end

      # Update status on lifecycle events
      state =
        case type do
          "session.idle" ->
            broadcast(state, {:session_status, :idle})
            %{state | status: :idle}

          "assistant.turn_start" ->
            broadcast(state, {:session_status, :thinking})
            %{state | status: :thinking}

          "tool.execution_start" ->
            broadcast(state, {:session_status, :tool_running})
            %{state | status: :tool_running}

          "tool.execution_complete" ->
            broadcast(state, {:session_status, :thinking})
            %{state | status: :thinking}

          _ ->
            state
        end

      broadcast(state, {:session_event, event_map})
      {:noreply, state}
    end
  end

  def handle_info(:stream_done, state) do
    Logger.info("Harness stream completed for #{state.agent} session #{state.id}")
    state = %{state | status: :idle, stream_task: nil}
    persist_status(state)
    broadcast(state, {:session_status, :idle})
    {:noreply, state}
  end

  def handle_info({:stream_error, reason}, state) do
    Logger.error("Harness stream error for #{state.agent}: #{inspect(reason)}")
    state = %{state | status: :idle, stream_task: nil}
    broadcast(state, {:session_error, "Agent error: #{inspect(reason)}"})
    broadcast(state, {:session_status, :idle})
    {:noreply, state}
  end

  # Task.async DOWN messages
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | stream_task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Clean up ask_user MCP server context for Claude sessions
    if state.ask_user_mcp_server_name do
      CopilotLv.AskUser.ClaudeTool.delete_context(state.ask_user_mcp_server_name)
    end

    :ok
  end

  # ── Ask User Support ──

  # Sets up ask_user infrastructure and returns {updated_state, agent_metadata}
  defp setup_ask_user_and_metadata(%{agent: :claude} = state, opts) do
    metadata = build_agent_metadata(state, opts)

    # Create MCP server with ask_user tool for Claude
    {server_name, mcp_server} = CopilotLv.AskUser.ClaudeTool.create_mcp_server(state.id)
    state = %{state | ask_user_mcp_server_name: server_name}

    Logger.info("Created ask_user MCP server '#{server_name}' for Claude session #{state.id}")

    # Merge MCP server config into metadata
    existing_mcp = metadata["mcp_servers"] || %{}
    updated_mcp = Map.put(existing_mcp, server_name, mcp_server)

    existing_allowed = metadata["allowed_tools"] || []
    tool_name = "mcp__#{server_name}__ask_user"
    updated_allowed = [tool_name | existing_allowed]

    # Disallow the built-in AskUserQuestion tool so Claude uses our MCP tool instead.
    # The built-in tool doesn't work in SDK/streaming mode (returns "Answer questions?" error).
    existing_disallowed = metadata["disallowed_tools"] || []
    updated_disallowed = ["AskUserQuestion" | existing_disallowed]

    metadata =
      metadata
      |> Map.put("mcp_servers", updated_mcp)
      |> Map.put("allowed_tools", updated_allowed)
      |> Map.put("disallowed_tools", updated_disallowed)

    Logger.info(
      "Claude ask_user metadata: mcp_servers=#{inspect(Map.keys(updated_mcp))}, allowed_tools=#{inspect(updated_allowed)}, disallowed_tools=#{inspect(updated_disallowed)}"
    )

    {state, metadata}
  end

  defp setup_ask_user_and_metadata(state, opts) do
    {state, build_agent_metadata(state, opts)}
  end

  # Handle Codex native RequestUserInput events
  defp handle_codex_user_input_request(state, event) do
    payload = event.payload
    questions = payload["questions"] || []
    request_id = payload["id"] || "codex-ask-#{System.unique_integer([:positive])}"

    # Codex questions come as a list of question objects, combine them
    question_text =
      questions
      |> Enum.map(fn
        %{"question" => q} -> q
        q when is_binary(q) -> q
        q when is_map(q) -> Map.get(q, "text") || Map.get(q, "question") || inspect(q)
        other -> inspect(other)
      end)
      |> Enum.join("\n\n")

    question_text = if question_text == "", do: "Codex needs your input", else: question_text

    # Extract choices if any question has them
    choices =
      questions
      |> Enum.flat_map(fn
        %{"choices" => c} when is_list(c) -> c
        %{"options" => o} when is_list(o) -> o
        _ -> []
      end)

    # Broadcast to LiveView to show the modal
    Phoenix.PubSub.broadcast(
      CopilotLv.PubSub,
      "session:#{state.id}",
      {:ask_user_request,
       %{
         request_id: request_id,
         question: question_text,
         choices: choices,
         allow_freeform: true
       }}
    )

    # Spawn a task to wait for the user's response and send it back to Codex
    Task.start(fn ->
      case CopilotLv.AskUserBroker.request(request_id, state.id, question_text, choices) do
        {:ok, answer} ->
          Logger.info("Codex ask_user response: #{answer}")
          # Note: For Codex, the response is sent back via the app server connection
          # which is managed by the Codex SDK stream. The SDK handles the response
          # flow internally when using the app_server transport.
          :ok

        {:error, :timeout} ->
          Logger.warning("Codex ask_user timed out for session #{state.id}")
      end
    end)

    # Also persist and broadcast as a regular event
    {type, data} = translate_event(event)
    state = %{state | event_count: state.event_count + 1, sequence: state.sequence + 1}

    raw_data = sanitize_raw_event(event)

    event_map = %{
      id: (event.raw && Map.get(event.raw, :id)) || "ev-#{System.unique_integer([:positive])}",
      type: type,
      data: data,
      raw_data: raw_data,
      timestamp: event.timestamp || DateTime.utc_now() |> DateTime.to_iso8601()
    }

    persist_event(state, event_map)
    broadcast(state, {:session_event, event_map})

    {:noreply, state}
  end

  # ── Event Translation ──
  # Translates Jido.Harness.Event types into copilot-native event vocabulary

  defp translate_event(%Jido.Harness.Event{type: type, payload: payload, session_id: sid}) do
    case type do
      :session_started ->
        {"session.start", %{"sessionId" => sid, "model" => payload["model"]}}

      :session_completed ->
        {"session.idle", payload}

      :session_failed ->
        {"session.error", %{"message" => payload["error"] || inspect(payload)}}

      :output_text_delta ->
        {"assistant.message", %{"chunkContent" => payload["text"], "content" => payload["text"]}}

      :output_text_final ->
        {"assistant.message", %{"content" => payload["text"]}}

      :thinking_delta ->
        {"assistant.reasoning", %{"content" => payload["text"]}}

      :tool_use_start ->
        {"tool.execution_start",
         %{
           "toolName" => payload["name"],
           "toolCallId" => payload["call_id"],
           "arguments" => payload["input"] || payload["arguments"] || %{}
         }}

      :tool_use_end ->
        {"tool.execution_complete",
         %{
           "toolCallId" => payload["call_id"],
           "result" => %{"content" => payload["output"] || ""},
           "success" => !payload["is_error"]
         }}

      :usage ->
        {"assistant.usage",
         %{
           "inputTokens" => payload["input_tokens"],
           "outputTokens" => payload["output_tokens"],
           "cacheReadTokens" =>
             payload["cache_read_input_tokens"] || payload["cached_input_tokens"],
           "cacheWriteTokens" => payload["cache_creation_input_tokens"],
           "model" => payload["model"],
           "cost" => payload["cost_usd"],
           "duration" => payload["duration_ms"]
         }}

      :turn_end ->
        {"assistant.turn_end", %{}}

      :user_message ->
        {"user.message", %{"content" => payload["text"]}}

      :turn_start ->
        {"assistant.turn_start", %{}}

      :ask_user ->
        {"ask_user.request",
         %{
           "questions" => payload["questions"] || [],
           "id" => payload["id"],
           "turn_id" => payload["turn_id"]
         }}

      :file_change ->
        {"file.change", payload}

      :provider_event ->
        translate_provider_event(payload)

      other ->
        {to_string(other), payload}
    end
  end

  defp translate_provider_event(%{"source" => "message_start"} = payload) do
    {"assistant.message_usage",
     %{
       "inputTokens" => payload["input_tokens"],
       "cacheReadTokens" => payload["cache_read_input_tokens"],
       "cacheWriteTokens" => payload["cache_creation_input_tokens"],
       "model" => payload["model"],
       "source" => "message_start"
     }}
  end

  defp translate_provider_event(%{"source" => "message_delta"} = payload) do
    {"assistant.message_usage",
     %{
       "outputTokens" => payload["output_tokens"],
       "stopReason" => payload["stop_reason"],
       "source" => "message_delta"
     }}
  end

  defp translate_provider_event(%{"source" => "stream_error"} = payload) do
    {"session.error",
     %{
       "message" => payload["message"],
       "errorType" => payload["error_type"],
       "source" => "stream_error"
     }}
  end

  defp translate_provider_event(payload) do
    {"provider_event", payload}
  end

  # ── Per-agent run options ──

  defp agent_run_opts(%{agent: :claude}) do
    [max_thinking_tokens: 10_000, verbose: true]
  end

  defp agent_run_opts(%{agent: :codex}), do: []
  defp agent_run_opts(%{agent: :gemini}), do: []
  defp agent_run_opts(_), do: []

  # ── Agent Metadata from Permissions ──

  defp build_agent_metadata(%{agent: :claude, permissions: perms}, opts) do
    permission_mode =
      case Map.get(perms, :permission_mode) do
        nil -> :bypass_permissions
        mode when is_atom(mode) -> mode
        mode when is_binary(mode) -> String.to_existing_atom(mode)
      end

    %{
      "max_thinking_tokens" => 10_000,
      "verbose" => true,
      "permission_mode" => permission_mode,
      "max_turns" => Keyword.get(opts, :max_turns, 10)
    }
  end

  defp build_agent_metadata(%{agent: :codex, permissions: perms}, _opts) do
    full_auto = Map.get(perms, :full_auto, false)

    if full_auto do
      %{
        "thread_opts" => %{
          "approval_policy" => "on-request",
          "sandbox_policy" => "workspace-write"
        }
      }
    else
      approval_policy = Map.get(perms, :approval_policy, "on-request")
      sandbox = Map.get(perms, :sandbox, "workspace-write")

      %{
        "thread_opts" => %{
          "approval_policy" => approval_policy,
          "sandbox_policy" => sandbox
        }
      }
    end
  end

  defp build_agent_metadata(%{agent: :gemini, permissions: perms}, _opts) do
    approval_mode = Map.get(perms, :approval_mode, "yolo")
    sandbox = Map.get(perms, :sandbox, false)

    meta = %{"approval_mode" => approval_mode}
    if sandbox, do: Map.put(meta, "sandbox", true), else: meta
  end

  defp build_agent_metadata(_state, _opts), do: %{}

  # ── Persistence helpers (same as SessionServer) ──

  defp persist_event(state, event) do
    event_id = event[:id] || event["id"]
    event_type = event[:type] || event["type"]
    data = event[:data] || event["data"] || %{}
    raw_data = event[:raw_data] || event["raw_data"]
    timestamp = normalize_datetime(event[:timestamp] || event["timestamp"])

    try do
      Ash.create!(Event, %{
        session_id: state.id,
        event_type: event_type,
        event_id: event_id,
        data: data,
        raw_data: raw_data,
        timestamp: timestamp,
        sequence: state.sequence
      })
    rescue
      e ->
        Logger.warning("Failed to persist event: #{Exception.message(e)}")
    end
  end

  defp sanitize_raw_event(%Jido.Harness.Event{} = event) do
    raw = event.raw

    cond do
      is_map(raw) && Map.has_key?(raw, :__struct__) ->
        Map.from_struct(raw) |> sanitize_values()

      is_map(raw) ->
        sanitize_values(raw)

      true ->
        %{
          "type" => to_string(event.type),
          "provider" => event.provider && to_string(event.provider),
          "session_id" => event.session_id,
          "timestamp" => event.timestamp,
          "payload" => event.payload
        }
    end
  end

  defp sanitize_values(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {k, %DateTime{} = dt}, acc -> Map.put(acc, to_string(k), DateTime.to_iso8601(dt))
      {k, v}, acc when is_atom(k) -> Map.put(acc, to_string(k), v)
      {k, v}, acc -> Map.put(acc, k, v)
    end)
  end

  defp persist_usage(state, entry) do
    try do
      Ash.create!(UsageEntry, Map.put(entry, :session_id, state.id))
    rescue
      e ->
        Logger.warning("Failed to persist usage: #{Exception.message(e)}")
    end
  end

  defp persist_status(state) do
    try do
      case Ash.get(Session, state.id) do
        {:ok, session} ->
          Ash.update!(session, %{status: state.status}, action: :update_status)

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  defp broadcast(state, message) do
    PubSub.broadcast(CopilotLv.PubSub, "session:#{state.id}", message)
  end

  defp normalize_datetime(nil), do: DateTime.utc_now()
  defp normalize_datetime(%DateTime{} = dt), do: dt

  defp normalize_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp normalize_datetime(_), do: DateTime.utc_now()
end
