defmodule CopilotLv.SessionServer do
  @moduledoc """
  GenServer managing a single Copilot CLI Server session.

  Wraps `Jido.GHCopilot.Server.Connection`, owns the session lifecycle,
  and broadcasts events to LiveView subscribers via PubSub.
  Persists all events and usage to SQLite via Ash.
  """
  use GenServer
  require Logger

  alias Jido.GHCopilot.Server.Connection
  alias CopilotLv.Sessions.{Event, UsageEntry, Session}
  alias Phoenix.PubSub

  defstruct [
    :id,
    :conn,
    :session_id,
    :model,
    :cwd,
    status: :starting,
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

  def switch_model(id, model) do
    GenServer.call(via(id), {:switch_model, model})
  end

  def get_state(id) do
    GenServer.call(via(id), :get_state)
  end

  def stop(id) do
    GenServer.stop(via(id), :normal)
  end

  def via(id), do: {:via, Registry, {CopilotLv.SessionRegistry.Registry, id}}

  @doc "PubSub topic for a session."
  def topic(id), do: "session:#{id}"

  # ── GenServer Callbacks ──

  @ask_user_tool %{
    name: "ask_user",
    description:
      "Ask the user a question and wait for their response. " <>
        "Use this tool when you need to ask the user questions during execution. " <>
        "Prefer providing choices when possible for faster UX.",
    parameters: %{
      type: "object",
      properties: %{
        question: %{type: "string", description: "The question to ask the user."},
        choices: %{
          type: "array",
          items: %{type: "string"},
          description: "Optional list of choices for a multiple choice question."
        },
        allow_freeform: %{
          type: "boolean",
          description:
            "Whether to allow freeform text input in addition to choices. Defaults to true.",
          default: true
        }
      },
      required: ["question"]
    }
  }

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    model = Keyword.get(opts, :model)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    # Extract the raw provider ID for use with the Copilot CLI API
    provider_session_id = CopilotLv.Sessions.Session.provider_id(id)

    state = %__MODULE__{
      id: id,
      model: model,
      cwd: cwd,
      session_id: provider_session_id
    }

    {:ok, state, {:continue, :start_connection}}
  end

  @impl true
  def handle_continue(:start_connection, state) do
    cli_args =
      ["--allow-all-tools", "--allow-all-paths", "--allow-all-urls"]
      |> maybe_append("--model", state.model)

    session_opts = %{
      model: state.model,
      session_id: state.session_id,
      tools: [@ask_user_tool]
    }

    Logger.info(
      "Creating session with external tools: #{inspect(Enum.map(@ask_user_tool[:parameters][:properties] |> Map.keys(), &to_string/1))}"
    )

    Logger.info("ask_user tool definition: #{inspect(@ask_user_tool[:name])}")

    case Connection.start_link(cli_args: cli_args, cwd: state.cwd) do
      {:ok, conn} ->
        # Try to resume if we have a previous copilot session ID
        result =
          if state.session_id do
            case Connection.resume_session(conn, state.session_id, %{tools: session_opts.tools}) do
              {:ok, session_id} -> {:ok, session_id}
              {:error, _} -> Connection.create_session(conn, session_opts)
            end
          else
            Connection.create_session(conn, session_opts)
          end

        case result do
          {:ok, session_id} ->
            :ok = Connection.subscribe(conn, session_id)
            state = %{state | conn: conn, session_id: session_id, status: :idle}
            persist_status(state)
            broadcast(state, {:session_status, :idle})
            {:noreply, state}

          {:error, reason} ->
            Logger.error("Failed to create/resume session: #{inspect(reason)}")
            broadcast(state, {:session_error, "Failed to create session: #{inspect(reason)}"})
            {:stop, {:session_create_failed, reason}, state}
        end

      {:error, reason} ->
        Logger.error("Failed to start connection: #{inspect(reason)}")
        broadcast(state, {:session_error, "Failed to start connection: #{inspect(reason)}"})
        {:stop, {:connection_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:send_prompt, _prompt, _opts}, _from, %{status: status} = state)
      when status not in [:idle] do
    {:reply, {:error, :not_idle}, state}
  end

  def handle_call({:send_prompt, prompt, opts}, _from, state) do
    requested_model = Keyword.get(opts, :model)

    # Switch model if requested and different from current
    state =
      if requested_model && requested_model != state.model do
        case do_switch_model(state, requested_model) do
          {:ok, new_state} -> new_state
          {:error, _reason} -> state
        end
      else
        state
      end

    state = %{state | status: :thinking, sequence: state.sequence + 1}
    broadcast(state, {:session_status, :thinking})

    # Persist user message (include attachment paths if present)
    attachments = Keyword.get(opts, :attachments, [])

    user_data =
      if attachments == [] do
        %{"content" => prompt}
      else
        %{"content" => prompt, "attachments" => Enum.map(attachments, &attachment_to_map/1)}
      end

    user_event = %{
      id: "user-#{System.unique_integer([:positive])}",
      type: "user.message",
      data: user_data,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    persist_event(state, user_event)

    send_opts = if attachments == [], do: %{}, else: %{attachments: attachments}

    case Connection.send_prompt(state.conn, state.session_id, prompt, send_opts) do
      {:ok, message_id} ->
        {:reply, {:ok, message_id}, state}

      {:error, reason} ->
        state = %{state | status: :idle}
        broadcast(state, {:session_status, :idle})
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    info = %{
      id: state.id,
      model: state.model,
      cwd: state.cwd,
      status: state.status,
      event_count: state.event_count,
      usage: Enum.reverse(state.usage)
    }

    {:reply, info, state}
  end

  def handle_call({:switch_model, model}, _from, %{status: :idle} = state) do
    case do_switch_model(state, model) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:switch_model, _model}, _from, state) do
    {:reply, {:error, :not_idle}, state}
  end

  @impl true
  def handle_info({:server_tool_call, %{tool_name: "ask_user"} = tool_call}, state) do
    Logger.info("Received ask_user tool call: #{inspect(tool_call)}")
    args = tool_call.arguments
    question = args["question"] || "Question from assistant"
    choices = args["choices"] || []
    allow_freeform = Map.get(args, "allow_freeform", true)

    request_id = tool_call.request_id

    # Spawn a task so we don't block the GenServer
    conn = state.conn

    Task.start(fn ->
      # Broadcast to LiveView to show modal
      Phoenix.PubSub.broadcast(
        CopilotLv.PubSub,
        "session:#{state.id}",
        {:ask_user_request,
         %{
           request_id: request_id,
           question: question,
           choices: choices,
           allow_freeform: allow_freeform
         }}
      )

      # Block until user responds (via AskUserBroker)
      case CopilotLv.AskUserBroker.request(request_id, state.id, question, choices) do
        {:ok, answer} ->
          Connection.respond_to_tool_call(conn, request_id, %{"result" => answer})

        {:error, :timeout} ->
          Connection.respond_to_tool_call(conn, request_id, %{
            "error" => "User did not respond in time"
          })
      end
    end)

    {:noreply, state}
  end

  def handle_info({:server_tool_call, %{tool_name: tool_name} = tool_call}, state) do
    Logger.warning("Unhandled external tool call: #{tool_name}")

    Connection.respond_to_tool_call(state.conn, tool_call.request_id, %{
      "error" => "Unknown tool: #{tool_name}"
    })

    {:noreply, state}
  end

  @impl true
  def handle_info({:server_event, %{type: type, data: data} = event}, state) do
    # Skip server-echoed user messages and noise (we persist our own in send_prompt)
    if type in ["user.message", "pending_messages.modified"] do
      {:noreply, state}
    else
      state = %{state | event_count: state.event_count + 1, sequence: state.sequence + 1}

      # Persist event to DB
      persist_event(state, event)

      # Track and persist usage
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

      # Update status on turn boundaries
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

      # Broadcast event to LiveView subscribers
      broadcast(state, {:session_event, event})

      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn} = _state) when not is_nil(conn) do
    Connection.stop(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Helpers ──

  defp broadcast(state, message) do
    PubSub.broadcast(CopilotLv.PubSub, topic(state.id), message)
  end

  defp maybe_append(args, _flag, nil), do: args
  defp maybe_append(args, flag, value), do: args ++ [flag, value]

  defp do_switch_model(state, model) do
    # Create new copilot session with new model (server protocol has no model-change RPC)
    if state.session_id, do: Connection.unsubscribe(state.conn, state.session_id)

    case Connection.create_session(state.conn, %{model: model}) do
      {:ok, new_session_id} ->
        :ok = Connection.subscribe(state.conn, new_session_id)
        new_state = %{state | session_id: new_session_id, model: model}
        broadcast(new_state, {:session_model_changed, model})
        persist_status(new_state)

        Logger.info("Switched model to #{model} (new copilot session: #{new_session_id})")
        {:ok, new_state}

      {:error, reason} ->
        # Re-subscribe to old session on failure
        if state.session_id, do: Connection.subscribe(state.conn, state.session_id)
        Logger.warning("Failed to switch model to #{model}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp persist_event(state, event) do
    event_id = map_get(event, :id) || map_get(event, "id")
    event_type = map_get(event, :type) || map_get(event, "type")
    data = map_get(event, :data) || map_get(event, "data") || %{}
    ts = map_get(event, :timestamp) || map_get(event, "timestamp")

    timestamp =
      case ts do
        %DateTime{} ->
          ts

        s when is_binary(s) ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> dt
            _ -> DateTime.utc_now()
          end

        _ ->
          DateTime.utc_now()
      end

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
      e -> Logger.warning("Failed to persist event: #{inspect(e)}")
    end
  end

  defp persist_usage(state, entry) do
    try do
      Ash.create!(UsageEntry, %{
        session_id: state.id,
        model: entry.model,
        input_tokens: entry.input_tokens,
        output_tokens: entry.output_tokens,
        cache_read_tokens: entry.cache_read_tokens,
        cache_write_tokens: entry.cache_write_tokens,
        cost: if(entry.cost, do: entry.cost / 1, else: nil),
        initiator: entry.initiator,
        duration_ms: entry.duration_ms
      })
    rescue
      e -> Logger.warning("Failed to persist usage: #{inspect(e)}")
    end
  end

  defp persist_status(state) do
    try do
      case Ash.get(Session, state.id) do
        {:ok, session} ->
          Ash.update!(
            session,
            %{
              status: state.status,
              model: state.model
            },
            action: :update_status
          )

        _ ->
          :ok
      end
    rescue
      e -> Logger.warning("Failed to persist status: #{inspect(e)}")
    end
  end

  defp map_get(%{__struct__: _} = struct, key) when is_atom(key), do: Map.get(struct, key)
  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
  defp map_get(_, _), do: nil

  defp attachment_to_map(%Jido.GHCopilot.Server.Types.Attachment{} = a) do
    %{"type" => to_string(a.type), "path" => a.path, "displayName" => a.display_name}
  end

  defp attachment_to_map(%{type: type, path: path} = a) do
    %{
      "type" => to_string(type),
      "path" => path,
      "displayName" => Map.get(a, :display_name, Path.basename(path))
    }
  end
end
