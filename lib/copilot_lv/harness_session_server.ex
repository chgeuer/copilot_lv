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

    adapter = Map.fetch!(@adapters, agent)

    state = %__MODULE__{
      id: id,
      agent: agent,
      adapter: adapter,
      model: model,
      cwd: cwd,
      status: :idle
    }

    persist_status(state)
    broadcast(state, {:session_status, :idle})

    {:ok, state}
  end

  @impl true
  def handle_call({:send_prompt, prompt, _opts}, _from, %{status: status} = state)
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

    # Build RunRequest for the adapter
    metadata_key = to_string(state.agent)

    agent_metadata =
      case state.agent do
        :claude ->
          %{
            "max_thinking_tokens" => 10_000,
            "verbose" => true,
            "dangerously_skip_permissions" => true,
            "max_turns" => Keyword.get(opts, :max_turns, 10)
          }

        :codex ->
          %{}

        :gemini ->
          %{"approval_mode" => :yolo}

        _ ->
          %{}
      end

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
  def handle_info({:harness_event, %Jido.Harness.Event{} = event}, state) do
    {type, data} = translate_event(event)

    if type in ["user.message"] do
      {:noreply, state}
    else
      state = %{state | event_count: state.event_count + 1, sequence: state.sequence + 1}

      # Build event map in copilot format
      event_map = %{
        id: event.raw && Map.get(event.raw, :id) || "ev-#{System.unique_integer([:positive])}",
        type: type,
        data: data,
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

      :tool_call ->
        {"tool.execution_start", %{
          "toolName" => payload["name"],
          "toolCallId" => payload["call_id"],
          "arguments" => payload["input"] || payload["arguments"] || %{}
        }}

      :tool_result ->
        {"tool.execution_complete", %{
          "toolCallId" => payload["call_id"],
          "result" => %{"content" => payload["output"] || ""},
          "success" => !payload["is_error"]
        }}

      :usage ->
        {"assistant.usage", %{
          "inputTokens" => payload["input_tokens"],
          "outputTokens" => payload["output_tokens"],
          "cacheReadTokens" => payload["cached_input_tokens"],
          "model" => payload["model"],
          "cost" => payload["cost_usd"],
          "duration" => payload["duration_ms"]
        }}

      :turn_end ->
        {"assistant.turn_end", %{}}

      :user_message ->
        {"user.message", %{"content" => payload["text"]}}

      :codex_turn_started ->
        {"assistant.turn_start", %{}}

      :file_change ->
        {"file.change", payload}

      other ->
        {to_string(other), payload}
    end
  end

  # ── Per-agent run options ──

  defp agent_run_opts(%{agent: :claude}) do
    [max_thinking_tokens: 10_000, verbose: true]
  end

  defp agent_run_opts(%{agent: :codex}), do: []
  defp agent_run_opts(%{agent: :gemini}), do: []
  defp agent_run_opts(_), do: []

  # ── Persistence helpers (same as SessionServer) ──

  defp persist_event(state, event) do
    event_id = event[:id] || event["id"]
    event_type = event[:type] || event["type"]
    data = event[:data] || event["data"] || %{}
    timestamp = normalize_datetime(event[:timestamp] || event["timestamp"])

    try do
      Ash.create!(Event, %{
        session_id: state.id,
        event_type: event_type,
        event_id: event_id,
        data: data,
        timestamp: timestamp,
        sequence: state.sequence
      })
    rescue
      e ->
        Logger.warning("Failed to persist event: #{Exception.message(e)}")
    end
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
