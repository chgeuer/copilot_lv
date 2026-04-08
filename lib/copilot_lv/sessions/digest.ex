defmodule CopilotLv.Sessions.Digest do
  @moduledoc """
  Generates a markdown digest of a session's conversation narrative.

  Extracts user messages, assistant messages, assistant reasoning, plan artifacts,
  and checkpoint summaries — excluding tool calls, usage stats, intents, and other
  operational noise. The output is designed to be fed to another coding agent for
  extracting learnings and avoiding repeated mistakes.
  """

  alias CopilotLv.Sessions.{Checkpoint, SessionArtifact}
  alias CopilotLv.SessionRegistry
  alias Jido.ToolRenderers.EventStream

  @type digest_opts :: [
          include_reasoning: boolean(),
          include_checkpoints: boolean(),
          include_plan: boolean(),
          include_file_artifacts: boolean()
        ]

  @default_opts [
    include_reasoning: true,
    include_checkpoints: true,
    include_plan: true,
    include_file_artifacts: true
  ]

  @doc """
  Generates a markdown digest for the given session ID.

  Returns `{:ok, markdown}` or `{:error, reason}`.
  """
  @spec generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def generate(session_id, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    case SessionRegistry.get_session(session_id) do
      {:ok, session} ->
        markdown = build_markdown(session, opts)
        {:ok, markdown}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp build_markdown(session, opts) do
    db_events = load_events(session)
    stream_events = build_stream_events(session, db_events)
    conversation = extract_conversation(stream_events)
    checkpoints = if opts[:include_checkpoints], do: load_checkpoints(session.id), else: []
    artifacts = load_artifacts(session.id)
    plan_artifact = Enum.find(artifacts, &(&1.artifact_type == :plan))
    file_artifacts = Enum.filter(artifacts, &(&1.artifact_type == :file))

    sections = [build_header(session, stream_events)]

    sections =
      if opts[:include_plan] && plan_artifact do
        sections ++ [build_plan_section(plan_artifact)]
      else
        sections
      end

    sections = sections ++ [build_conversation_section(conversation, opts)]

    sections =
      if opts[:include_checkpoints] && checkpoints != [] do
        sections ++ [build_checkpoints_section(checkpoints)]
      else
        sections
      end

    sections =
      if opts[:include_file_artifacts] && file_artifacts != [] do
        sections ++ [build_file_artifacts_section(file_artifacts)]
      else
        sections
      end

    Enum.join(sections, "\n\n---\n\n")
  end

  # ── Data loading ──

  defp load_events(session) do
    CopilotLv.Sessions.Event
    |> Ash.Query.for_read(:for_session, %{session_id: session.id})
    |> Ash.read!()
    |> Enum.map(fn e ->
      data = e.data || %{}

      data =
        if session.agent == :copilot && is_map(data["data"]) && data["type"] == e.event_type do
          data["data"]
        else
          data
        end

      %{
        id: e.id,
        type: e.event_type,
        data: data,
        dom_id: "db-#{e.id}",
        timestamp: e.timestamp,
        sequence: e.sequence
      }
    end)
  end

  defp build_stream_events(session, db_events) do
    event_format = detect_event_format(session.agent || :copilot, db_events)
    EventStream.build_events(db_events, event_format)
  end

  defp detect_event_format(agent, db_events) do
    event_types = MapSet.new(db_events, & &1.type)

    case agent do
      :claude ->
        if MapSet.size(MapSet.intersection(event_types, MapSet.new(["user", "assistant"]))) > 0,
          do: :claude,
          else: :copilot

      :codex ->
        if MapSet.size(MapSet.intersection(event_types, MapSet.new(["response_item"]))) > 0,
          do: :codex,
          else: :copilot

      :gemini ->
        if MapSet.size(MapSet.intersection(event_types, MapSet.new(["gemini"]))) > 0,
          do: :gemini,
          else: :copilot

      :pi ->
        if MapSet.size(MapSet.intersection(event_types, MapSet.new(["message"]))) > 0,
          do: :pi,
          else: :copilot

      other ->
        other
    end
  end

  defp load_checkpoints(session_id) do
    Checkpoint
    |> Ash.Query.for_read(:for_session, %{session_id: session_id})
    |> Ash.read!()
  end

  defp load_artifacts(session_id) do
    SessionArtifact
    |> Ash.Query.for_read(:for_session, %{session_id: session_id})
    |> Ash.read!()
  end

  # ── Conversation extraction ──

  defp extract_conversation(stream_events) do
    stream_events
    |> Enum.flat_map(fn event ->
      case event.type do
        type when type in ["user.message", "assistant.message.block", "assistant.reasoning"] ->
          [%{type: type, content: event.data["content"] || ""}]

        "tool.group" ->
          # Extract only assistant messages and reasoning from within tool groups
          events = event.data["events"] || []

          events
          |> Enum.flat_map(fn child ->
            child_type =
              case child do
                %{type: t} when is_binary(t) -> t
                %Jido.ToolRenderers.SessionEvent{type: t} -> Atom.to_string(t)
                _ -> nil
              end

            child_data =
              case child do
                %{data: d} -> d
                _ -> %{}
              end

            case child_type do
              t when t in ["assistant.message.block", "assistant_message"] ->
                content = child_data["content"] || ""
                if String.trim(content) != "", do: [%{type: "assistant.message.block", content: content}], else: []

              t when t in ["assistant.reasoning", "assistant_reasoning"] ->
                content = child_data["content"] || ""
                if String.trim(content) != "", do: [%{type: "assistant.reasoning", content: content}], else: []

              _ ->
                []
            end
          end)

        _ ->
          []
      end
    end)
    |> Enum.filter(fn entry -> String.trim(entry.content) != "" end)
  end

  # ── Markdown rendering ──

  defp build_header(session, stream_events) do
    user_count = Enum.count(stream_events, &(&1.type == "user.message"))
    assistant_count = Enum.count(stream_events, &(&1.type == "assistant.message.block"))
    tool_group_count = Enum.count(stream_events, &(&1.type == "tool.group"))

    agent_name = session.agent |> Atom.to_string() |> String.capitalize()

    started =
      if session.started_at,
        do: Calendar.strftime(session.started_at, "%Y-%m-%d %H:%M UTC"),
        else: "unknown"

    """
    # Session Digest

    | Field | Value |
    |-------|-------|
    | **Session ID** | `#{session.id}` |
    | **Agent** | #{agent_name} |
    | **Model** | #{session.model || "unknown"} |
    | **Working Directory** | `#{session.cwd}` |
    | **Started** | #{started} |
    | **Status** | #{session.status} |
    | **User Messages** | #{user_count} |
    | **Assistant Responses** | #{assistant_count} |
    | **Tool Groups** | #{tool_group_count} |
    """
    |> String.trim()
  end

  defp build_plan_section(plan_artifact) do
    """
    ## Plan

    #{plan_artifact.content}
    """
    |> String.trim()
  end

  defp build_conversation_section(conversation, opts) do
    entries =
      conversation
      |> Enum.map(fn entry ->
        case entry.type do
          "user.message" ->
            "### User\n\n#{entry.content}"

          "assistant.message.block" ->
            "### Assistant\n\n#{entry.content}"

          "assistant.reasoning" ->
            if opts[:include_reasoning] do
              "### Reasoning\n\n#{entry.content}"
            end

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    """
    ## Conversation

    #{entries}
    """
    |> String.trim()
  end

  defp build_checkpoints_section(checkpoints) do
    entries =
      checkpoints
      |> Enum.map(fn checkpoint ->
        header = "### Checkpoint #{checkpoint.number}: #{checkpoint.title || checkpoint.filename || "Untitled"}"

        structured_parts =
          [
            if(checkpoint.overview && String.trim(checkpoint.overview) != "",
              do: "\n**Overview:**\n#{checkpoint.overview}"),
            if(checkpoint.work_done && String.trim(checkpoint.work_done) != "",
              do: "\n**Work Done:**\n#{checkpoint.work_done}"),
            if(checkpoint.next_steps && String.trim(checkpoint.next_steps) != "",
              do: "\n**Next Steps:**\n#{checkpoint.next_steps}"),
            if(checkpoint.technical_details && String.trim(checkpoint.technical_details) != "",
              do: "\n**Technical Details:**\n#{checkpoint.technical_details}"),
            if(checkpoint.important_files && String.trim(checkpoint.important_files) != "",
              do: "\n**Important Files:**\n#{checkpoint.important_files}")
          ]
          |> Enum.reject(&is_nil/1)

        content_part =
          if structured_parts == [] && checkpoint.content && String.trim(checkpoint.content) != "" do
            ["\n#{checkpoint.content}"]
          else
            []
          end

        Enum.join([header] ++ structured_parts ++ content_part, "\n")
      end)
      |> Enum.join("\n\n")

    """
    ## Checkpoints

    #{entries}
    """
    |> String.trim()
  end

  defp build_file_artifacts_section(file_artifacts) do
    entries =
      file_artifacts
      |> Enum.map(fn artifact ->
        size = format_bytes(artifact.size || 0)

        """
        ### #{artifact.path} (#{size})

        ```
        #{String.slice(artifact.content || "", 0, 2000)}
        ```
        """
        |> String.trim()
      end)
      |> Enum.join("\n\n")

    """
    ## File Artifacts

    #{entries}
    """
    |> String.trim()
  end

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"
end
