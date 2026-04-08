defmodule CopilotLv.AskUser.ClaudeTool do
  @moduledoc """
  In-process MCP tool for Claude that allows the LLM to ask the user a question
  and wait for their response via the LiveView modal.

  This tool is registered as an SDK-based MCP server tool with the Claude adapter.
  When Claude calls it, the `execute/1` callback blocks until the user responds
  (via `AskUserBroker`), then returns the answer to Claude.

  ## Session Context

  The tool needs to know which session it belongs to in order to broadcast the
  question to the correct LiveView. This is stored in a module-level ETS table
  keyed by the MCP server's registry PID (which is unique per session).
  """

  use ClaudeAgentSDK.Tool

  @context_table :ask_user_claude_context

  # ── Context Management ──

  @doc """
  Initializes the ETS table for storing session context.
  Called once at application startup.
  """
  def init_context_table do
    if :ets.whereis(@context_table) == :undefined do
      :ets.new(@context_table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc """
  Stores the session context for a given MCP server registry PID.
  Called by HarnessSessionServer before starting a Claude query.
  """
  def put_context(registry_pid, session_id) when is_pid(registry_pid) do
    init_context_table()
    :ets.insert(@context_table, {registry_pid, session_id})
    :ok
  end

  def put_context(server_name, session_id) when is_binary(server_name) do
    init_context_table()
    :ets.insert(@context_table, {server_name, session_id})
    :ok
  end

  @doc """
  Removes the session context.
  Called when the session ends.
  """
  def delete_context(key) do
    :ets.delete(@context_table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── MCP Server Setup ──

  @doc """
  Creates an SDK MCP server with the ask_user tool registered.

  Returns `{server_name, server}` suitable for passing to Claude SDK Options.mcp_servers.
  Also stores the session context so the tool can broadcast to the correct LiveView.
  """
  def create_mcp_server(session_id) do
    server_name = "ask_user_#{session_id}"

    server =
      ClaudeAgentSDK.create_sdk_mcp_server(
        name: server_name,
        version: "1.0.0",
        tools: [__MODULE__.AskUser]
      )

    # Store session context keyed by both server_name and registry_pid
    put_context(server_name, session_id)

    if is_pid(server.registry_pid) do
      put_context(server.registry_pid, session_id)
    end

    {server_name, server}
  end

  # ── Tool Definition ──

  deftool :ask_user,
          "Ask the user a question and wait for their response. " <>
            "Use this tool when you need to ask the user questions during execution. " <>
            "Prefer providing choices when possible for faster UX.",
          %{
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
          } do
    def execute(input) do
      question = input["question"] || "Question from assistant"

      choices =
        case input["choices"] do
          nil -> []
          list when is_list(list) -> list
          _ -> []
        end

      allow_freeform = Map.get(input, "allow_freeform", true)

      # Generate a unique request ID
      request_id = "claude-ask-#{System.unique_integer([:positive])}"

      # Find the session ID from the ETS context table.
      # This task was spawned by the Tool.Registry's TaskSupervisor, so we trace
      # back through ancestors to find the registry PID, then look up the session.
      session_id = find_session_id()

      case session_id do
        nil ->
          {:ok,
           %{
             "content" => [
               %{
                 "type" => "text",
                 "text" => "Error: Could not determine session context for ask_user tool."
               }
             ],
             "is_error" => true
           }}

        session_id ->
          # Broadcast to LiveView to show the modal
          Phoenix.PubSub.broadcast(
            CopilotLv.PubSub,
            "session:#{session_id}",
            {:ask_user_request,
             %{
               request_id: request_id,
               question: question,
               choices: choices,
               allow_freeform: allow_freeform
             }}
          )

          # Block until user responds (via AskUserBroker)
          case CopilotLv.AskUserBroker.request(request_id, session_id, question, choices) do
            {:ok, answer} ->
              {:ok,
               %{
                 "content" => [
                   %{"type" => "text", "text" => answer}
                 ]
               }}

            {:error, :timeout} ->
              {:ok,
               %{
                 "content" => [
                   %{
                     "type" => "text",
                     "text" => "User did not respond in time."
                   }
                 ],
                 "is_error" => true
               }}
          end
      end
    end

    defp find_session_id do
      table = :ask_user_claude_context

      # Strategy 1: Check if any ancestor PID is a registered context
      ancestors =
        (Process.get(:"$callers") || []) ++ (Process.get(:"$ancestors") || [])

      ancestor_match =
        Enum.find_value(ancestors, fn pid ->
          case :ets.lookup(table, pid) do
            [{^pid, session_id}] -> session_id
            _ -> nil
          end
        end)

      if ancestor_match do
        ancestor_match
      else
        # Strategy 2: Fall back to scanning all entries
        case :ets.tab2list(table) do
          [] ->
            nil

          entries ->
            # Filter to only string-keyed entries (server names, not PIDs)
            name_entries = Enum.filter(entries, fn {k, _v} -> is_binary(k) end)

            case name_entries do
              [{_server_name, session_id}] ->
                session_id

              [_ | _] ->
                # Multiple sessions - use the last one (most recent)
                {_server_name, session_id} = List.last(name_entries)
                session_id

              [] ->
                # Only PID entries, use any
                {_key, session_id} = List.first(entries)
                session_id
            end
        end
      end
    rescue
      ArgumentError -> nil
    end
  end
end
