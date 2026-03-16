defmodule CopilotLv.SessionHandoff do
  @moduledoc """
  Builds an agent-oriented handoff document for a persisted session.
  """

  alias CopilotLv.SessionHandoff.Extractor
  alias CopilotLv.Sessions.{Checkpoint, Event, Session, SessionArtifact, SessionTodo, UsageEntry}

  @default_max_assistant_chars 12_000
  @default_max_command_output_chars 4_000

  def generate(session_ref, opts \\ []) do
    with {:ok, session} <- resolve_session(session_ref, opts) do
      handoff = build_handoff(session, opts)
      markdown = render_markdown(handoff, opts)
      {:ok, %{session: handoff.session, handoff: handoff, markdown: markdown}}
    end
  end

  def takeover_prompt(handoff_url) do
    """
    You are taking over a coding task from a prior agent session.

    Download the handoff history by running:

    curl --silent #{handoff_url}

    Treat the response as the previous agent's authoritative working history. Before making changes, verify the repository state on disk still matches the recorded context. Then continue from the Outstanding Work, Commands Executed, Todos, and Continuation Notes sections.
    """
    |> String.trim()
  end

  defp build_handoff(session, opts) do
    events = load_events(session)
    extracted = Extractor.extract(session, events)
    artifacts = load_records(SessionArtifact, :for_session, session.id)
    checkpoints = load_records(Checkpoint, :for_session, session.id)
    todos = load_records(SessionTodo, :for_session, session.id)
    usage = load_records(UsageEntry, :for_session, session.id)

    continuation = build_continuation(session, extracted, todos)

    %{
      session: session_summary(session),
      prompts: extracted.prompts,
      assistant_outputs: extracted.assistant_outputs,
      operations: extracted.operations,
      artifacts: artifacts,
      todos: todos,
      checkpoints: checkpoints,
      usage: usage,
      continuation: continuation,
      relative_to: Keyword.get(opts, :relative_to),
      options: effective_options(opts)
    }
  end

  defp session_summary(session) do
    %{
      id: session.id,
      provider_id: Session.provider_id(session.id),
      agent: session.agent || :copilot,
      cwd: session.cwd,
      hostname: session.hostname,
      git_root: session.git_root,
      branch: session.branch,
      model: session.model,
      started_at: session.started_at,
      stopped_at: session.stopped_at,
      source: session.source,
      event_count: session.event_count || 0,
      title: session.title,
      summary: session.summary
    }
  end

  defp effective_options(opts) do
    %{
      full_transcript: truthy?(Keyword.get(opts, :full_transcript, false)),
      max_assistant_chars: Keyword.get(opts, :max_assistant_chars, @default_max_assistant_chars),
      max_command_output_chars:
        Keyword.get(opts, :max_command_output_chars, @default_max_command_output_chars)
    }
  end

  defp resolve_session(session_ref, opts) do
    requested_agent = normalize_agent(Keyword.get(opts, :agent))

    sessions =
      Session
      |> Ash.Query.for_read(:list_all)
      |> Ash.read!()

    exact_match =
      Enum.find(sessions, fn session ->
        session.id == session_ref && (is_nil(requested_agent) || session.agent == requested_agent)
      end)

    cond do
      exact_match ->
        {:ok, exact_match}

      is_nil(requested_agent) == false ->
        provider_matches =
          Enum.filter(sessions, fn session ->
            session.agent == requested_agent && Session.provider_id(session.id) == session_ref
          end)

        resolve_provider_matches(provider_matches)

      true ->
        provider_matches =
          Enum.filter(sessions, fn session -> Session.provider_id(session.id) == session_ref end)

        resolve_provider_matches(provider_matches)
    end
  end

  defp resolve_provider_matches([]), do: {:error, :not_found}
  defp resolve_provider_matches([session]), do: {:ok, session}

  defp resolve_provider_matches(matches) do
    {:error, {:ambiguous, Enum.map(matches, & &1.id)}}
  end

  defp load_events(session) do
    Event
    |> Ash.Query.for_read(:for_session, %{session_id: session.id})
    |> Ash.read!()
    |> Enum.map(fn event ->
      data = normalize_event_data(session.agent, event.event_type, event.data || %{})

      %{
        id: event.id,
        type: event.event_type,
        data: data,
        sequence: event.sequence,
        timestamp: event.timestamp
      }
    end)
    |> Enum.sort_by(& &1.sequence)
  end

  defp normalize_event_data(:copilot, event_type, data) when is_map(data) do
    if is_map(data["data"]) && data["type"] == event_type do
      data["data"]
    else
      data
    end
  end

  defp normalize_event_data(_agent, _event_type, data), do: data

  defp load_records(resource, action, session_id) do
    resource
    |> Ash.Query.for_read(action, %{session_id: session_id})
    |> Ash.read!()
  end

  defp build_continuation(_session, extracted, todos) do
    open_todos = Enum.filter(todos, &(&1.status != "done"))
    last_intent = latest_intent(extracted.operations)
    last_user_goal = extracted.prompts |> List.last() |> then(&if(&1, do: &1.text))

    last_assistant_summary =
      extracted.assistant_outputs
      |> List.last()
      |> then(&if(&1, do: &1.text))
      |> truncate_inline(240)

    incomplete_operations =
      Enum.filter(extracted.operations, fn operation ->
        operation.kind in [:command, :file_read, :file_write, :file_delete, :search] &&
          is_nil(operation.completed_sequence)
      end)

    likely_next_step =
      cond do
        open_todos != [] ->
          "Continue with open todo: #{hd(open_todos).title}"

        last_intent ->
          "Continue with the agent's last reported intent: #{last_intent}"

        last_user_goal ->
          "Continue addressing the last user goal: #{truncate_inline(last_user_goal, 180)}"

        true ->
          nil
      end

    %{
      last_user_goal: last_user_goal,
      last_assistant_summary: last_assistant_summary,
      last_intent: last_intent,
      open_todos: open_todos,
      incomplete_operations: incomplete_operations,
      likely_next_step: likely_next_step,
      quota_limited?: quota_limited?(extracted)
    }
  end

  defp latest_intent(operations) do
    operations
    |> Enum.filter(&(&1.kind == :intent))
    |> List.last()
    |> then(&if(&1, do: &1.summary))
  end

  defp quota_limited?(extracted) do
    texts =
      extracted.assistant_outputs
      |> Enum.map(& &1.text)
      |> Kernel.++(Enum.map(extracted.prompts, & &1.text))

    Enum.any?(texts, fn text ->
      text = String.downcase(text || "")

      String.contains?(text, "rate_limit") ||
        String.contains?(text, "rate limit") ||
        String.contains?(text, "quota") ||
        String.contains?(text, "out of extra usage") ||
        String.contains?(text, "usage limit")
    end)
  end

  defp render_markdown(handoff, _opts) do
    reads = aggregate_reads(handoff.operations, handoff.relative_to)
    writes = aggregate_writes(handoff.operations, handoff.relative_to)
    commands = command_operations(handoff.operations)
    searches = search_operations(handoff.operations, handoff.relative_to)
    transcript = transcript_entries(handoff)

    counts = %{
      file_reads: length(reads),
      file_writes: length(writes),
      commands: length(commands),
      searches: length(searches)
    }

    [
      render_front_matter(handoff, counts),
      "# Session Handoff\n",
      render_resume_instructions(),
      render_session_summary(handoff, counts),
      render_outstanding_work(handoff),
      render_files_read(reads),
      render_files_written(writes),
      render_commands(commands, handoff.options.max_command_output_chars),
      render_searches(searches),
      render_todos(handoff.todos),
      render_checkpoints(handoff.checkpoints),
      render_transcript(transcript, handoff.options),
      render_continuation_notes(handoff)
    ]
    |> Enum.join("\n")
  end

  defp render_front_matter(handoff, counts) do
    session = handoff.session

    [
      "<!-- copilot-lv-session-handoff:v1 -->",
      "---",
      "session_id: #{yaml_scalar(session.id)}",
      "provider_id: #{yaml_scalar(session.provider_id)}",
      "agent: #{yaml_scalar(session.agent)}",
      "hostname: #{yaml_scalar(session.hostname)}",
      "cwd: #{yaml_scalar(session.cwd)}",
      "git_root: #{yaml_scalar(session.git_root)}",
      "branch: #{yaml_scalar(session.branch)}",
      "model: #{yaml_scalar(session.model)}",
      "started_at: #{yaml_scalar(format_timestamp(session.started_at))}",
      "stopped_at: #{yaml_scalar(format_timestamp(session.stopped_at))}",
      "source: #{yaml_scalar(session.source)}",
      "event_count: #{session.event_count}",
      "operation_counts:",
      "  file_reads: #{counts.file_reads}",
      "  file_writes: #{counts.file_writes}",
      "  commands: #{counts.commands}",
      "  searches: #{counts.searches}",
      "---"
    ]
    |> Enum.join("\n")
  end

  defp render_resume_instructions do
    [
      "## Resume Instructions",
      "- Treat this document as authoritative history from the prior coding agent session.",
      "- Re-check the current repository state before editing or running commands.",
      "- Continue from the Outstanding Work and Continuation Notes sections first, then inspect the transcript and command history as needed."
    ]
    |> Enum.join("\n")
  end

  defp render_session_summary(handoff, counts) do
    session = handoff.session
    continuation = handoff.continuation

    quota_suffix =
      if continuation.quota_limited? do
        " A quota or rate-limit signal was detected near the end of the session."
      else
        ""
      end

    summary_paragraph =
      "This was a #{session.agent} session running from #{format_timestamp(session.started_at)} to #{format_timestamp(session.stopped_at)} in #{session.cwd || "unknown cwd"} on branch #{session.branch || "unknown"} using #{session.model || "unknown model"}. " <>
        "It read #{counts.file_reads} files, wrote #{counts.file_writes} files, ran #{counts.commands} commands, and performed #{counts.searches} searches. " <>
        "The last visible user goal was #{inline_sentence(continuation.last_user_goal)}." <>
        quota_suffix

    [
      "## Session Summary",
      "- agent: `#{session.agent}`",
      "- timeframe: `#{format_timestamp(session.started_at)}` → `#{format_timestamp(session.stopped_at)}`",
      "- cwd: `#{session.cwd || "unknown"}`",
      "- git root: `#{session.git_root || "unknown"}`",
      "- branch: `#{session.branch || "unknown"}`",
      "- model: `#{session.model || "unknown"}`",
      "",
      summary_paragraph
    ]
    |> Enum.join("\n")
  end

  defp render_outstanding_work(handoff) do
    continuation = handoff.continuation

    todo_lines =
      case continuation.open_todos do
        [] -> ["- open todos: none captured"]
        todos -> Enum.map(todos, fn todo -> "- open todo: #{todo.title} (`#{todo.todo_id}`)" end)
      end

    incomplete_lines =
      case continuation.incomplete_operations do
        [] ->
          ["- incomplete tool calls: none captured"]

        operations ->
          Enum.map(operations, fn operation ->
            label =
              operation.summary || operation.command || operation.path || operation.tool ||
                "operation"

            "- incomplete operation: #{label} (sequence #{format_sequence_range(operation)})"
          end)
      end

    [
      "## Outstanding Work",
      "- last user goal: #{inline_sentence(continuation.last_user_goal)}",
      "- last reported intent: #{inline_sentence(continuation.last_intent)}",
      "- likely next step: #{inline_sentence(continuation.likely_next_step)}",
      ""
      | todo_lines ++ [""] ++ incomplete_lines
    ]
    |> Enum.join("\n")
  end

  defp render_files_read([]), do: "## Files Read\n_No file reads captured._"

  defp render_files_read(reads) do
    lines =
      Enum.map(reads, fn read ->
        count_suffix = if read.count > 1, do: ", repeated #{read.count} times", else: ""

        "- Read `#{format_read_target(read.path, read.read_span)}` via `#{Enum.join(read.via, ", ")}` " <>
          "(#{read.confidence}, sequences #{Enum.join(read.sequences, ", ")}#{count_suffix})"
      end)

    ["## Files Read" | lines]
    |> Enum.join("\n")
  end

  defp render_files_written([]), do: "## Files Written\n_No file writes captured._"

  defp render_files_written(writes) do
    lines =
      Enum.map(writes, fn write ->
        "- #{write_action_phrase(write.action)} `#{write.path}` via `#{Enum.join(write.via, ", ")}` " <>
          "(#{write.confidence}, sequences #{Enum.join(write.sequences, ", ")})"
      end)

    ["## Files Written" | lines]
    |> Enum.join("\n")
  end

  defp render_commands([], _max_chars), do: "## Commands Executed\n_No commands captured._"

  defp render_commands(commands, max_chars) do
    rendered =
      commands
      |> Enum.with_index(1)
      |> Enum.map(fn {command, index} ->
        result_excerpt = truncate_text(command.result_excerpt, max_chars)
        exit_status = extract_exit_status(command)

        [
          "### Command #{index}",
          "- tool: `#{command.tool || "unknown"}`",
          "- class: `#{command.command_class || "command"}`",
          "- workdir: `#{command.workdir || "unknown"}`",
          "- confidence: `#{command.confidence}`",
          "- sequences: `#{format_sequence_range(command)}`",
          if(command.summary, do: "- summary: #{command.summary}"),
          if(exit_status != nil,
            do: "- exit status: `#{exit_status}`",
            else: "- success: `#{command.success}`"
          ),
          "",
          fenced_block(command.command || "", "bash"),
          "",
          "Result summary:",
          render_command_result(command, result_excerpt)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end)

    ["## Commands Executed" | rendered]
    |> Enum.join("\n\n")
  end

  defp render_searches([]), do: "## Searches\n_No searches captured._"

  defp render_searches(searches) do
    lines =
      Enum.map(searches, fn search ->
        "- `#{search.summary || "search"}` via `#{Enum.join(search.via, ", ")}` " <>
          "(#{search.confidence}, sequences #{Enum.join(search.sequences, ", ")})"
      end)

    ["## Searches" | lines]
    |> Enum.join("\n")
  end

  defp render_todos([]), do: "## Todos\n_No session todos captured._"

  defp render_todos(todos) do
    lines =
      Enum.map(todos, fn todo ->
        deps =
          case todo.depends_on do
            [] -> ""
            deps -> " (depends on: #{Enum.join(deps, ", ")})"
          end

        "- [#{todo.status}] #{todo.title} (`#{todo.todo_id}`)#{deps}"
      end)

    ["## Todos" | lines]
    |> Enum.join("\n")
  end

  defp render_checkpoints([]), do: "## Checkpoints\n_No checkpoints captured._"

  defp render_checkpoints(checkpoints) do
    rows =
      Enum.map(checkpoints, fn checkpoint ->
        [
          Integer.to_string(checkpoint.number),
          md_cell(checkpoint.title || checkpoint.filename || "checkpoint")
        ]
      end)

    ["## Checkpoints", markdown_table(["number", "title"], rows)]
    |> Enum.join("\n")
  end

  defp render_transcript([], _options),
    do: "## Conversation Transcript\n_No transcript captured._"

  defp render_transcript(entries, options) do
    {rendered, _user_count, _assistant_count, _commit_count} =
      Enum.reduce(entries, {[], 0, 0, 0}, fn entry,
                                             {acc, user_count, assistant_count, commit_count} ->
        case entry.role do
          :user ->
            heading = "### User #{user_count + 1} @ #{format_timestamp(entry.timestamp)}"
            section = [heading, fenced_block(entry.text || "", "text")] |> Enum.join("\n\n")
            {[section | acc], user_count + 1, assistant_count, commit_count}

          :assistant ->
            heading =
              "### Assistant #{assistant_count + 1} @ #{format_timestamp(entry.timestamp)}"

            text =
              if options.full_transcript do
                entry.text
              else
                truncate_text(entry.text, options.max_assistant_chars)
              end

            section = [heading, fenced_block(text || "", "text")] |> Enum.join("\n\n")
            {[section | acc], user_count, assistant_count + 1, commit_count}

          :commit ->
            heading =
              "### Commit Message #{commit_count + 1} @ #{format_timestamp(entry.timestamp)}"

            section = [heading, fenced_block(entry.text || "", "text")] |> Enum.join("\n\n")
            {[section | acc], user_count, assistant_count, commit_count + 1}
        end
      end)

    ["## Conversation Transcript" | Enum.reverse(rendered)]
    |> Enum.join("\n\n")
  end

  defp render_continuation_notes(handoff) do
    continuation = handoff.continuation

    [
      "## Continuation Notes",
      "1. Verify the repository state still matches the recorded cwd, branch, and changed files before editing.",
      "2. Re-run the last relevant command if you need to re-establish current failure or success state.",
      "3. Continue from #{inline_sentence(continuation.likely_next_step)}"
    ]
    |> Enum.join("\n")
  end

  defp aggregate_reads(operations, relative_to) do
    operations
    |> Enum.filter(&(&1.kind == :file_read && is_binary(&1.path)))
    |> Enum.group_by(&{&1.path, &1.read_span})
    |> Enum.map(fn {{path, read_span}, entries} ->
      %{
        path: display_path(path, relative_to),
        read_span: read_span,
        via: entries |> Enum.map(&(&1.tool || "tool")) |> Enum.uniq() |> Enum.sort(),
        count: length(entries),
        confidence: aggregate_confidence(entries),
        sequences: entries |> Enum.map(&format_sequence_range/1) |> Enum.uniq()
      }
    end)
    |> Enum.sort_by(&{&1.path, &1.read_span || ""})
  end

  defp aggregate_writes(operations, relative_to) do
    operations
    |> Enum.filter(&(&1.kind in [:file_write, :file_delete] && is_binary(&1.path)))
    |> Enum.group_by(&{&1.path, &1.action || "touched"})
    |> Enum.map(fn {{path, action}, entries} ->
      %{
        path: display_path(path, relative_to),
        action: action,
        via: entries |> Enum.map(&(&1.tool || "tool")) |> Enum.uniq() |> Enum.sort(),
        confidence: aggregate_confidence(entries),
        sequences: entries |> Enum.map(&format_sequence_range/1) |> Enum.uniq()
      }
    end)
    |> Enum.sort_by(&{&1.path, &1.action})
  end

  defp search_operations(operations, relative_to) do
    operations
    |> Enum.filter(&(&1.kind == :search))
    |> Enum.map(fn operation ->
      %{
        summary:
          operation.summary ||
            [operation.path && display_path(operation.path, relative_to)]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" "),
        via: [operation.tool || "tool"],
        confidence: operation.confidence,
        sequences: [format_sequence_range(operation)]
      }
    end)
  end

  defp command_operations(operations) do
    operations
    |> Enum.filter(&(&1.kind == :command && is_binary(&1.command)))
    |> Enum.sort_by(&{&1.started_sequence || 0, &1.command || ""})
  end

  defp transcript_entries(handoff) do
    user_entries = Enum.map(handoff.prompts, &Map.put(&1, :role, :user))

    assistant_entries =
      Enum.map(handoff.assistant_outputs, fn output ->
        %{
          role: :assistant,
          sequence: output.sequence_start,
          timestamp: output.timestamp,
          text: output.text
        }
      end)

    commit_entries =
      handoff.operations
      |> Enum.filter(&(&1.kind == :command && is_binary(&1.command)))
      |> Enum.flat_map(fn operation ->
        operation.command
        |> extract_commit_messages()
        |> Enum.with_index()
        |> Enum.map(fn {message, index} ->
          %{
            role: :commit,
            sequence: operation.completed_sequence || operation.started_sequence || 0,
            timestamp: operation.timestamp,
            text: message,
            sort_offset: index
          }
        end)
      end)

    (user_entries ++ assistant_entries ++ commit_entries)
    |> Enum.sort_by(&transcript_sort_key/1)
  end

  defp aggregate_confidence(entries) do
    cond do
      Enum.any?(entries, &(&1.confidence == :structured)) -> :structured
      Enum.any?(entries, &(&1.confidence == :inferred)) -> :inferred
      true -> :unknown
    end
  end

  defp extract_exit_status(command) do
    cond do
      is_binary(command.result_excerpt) ->
        case Regex.run(~r/Exit code:\s*(-?\d+)/, command.result_excerpt) do
          [_, code] -> code
          _ -> nil
        end

      command.success == true ->
        "0"

      command.success == false ->
        "1"

      true ->
        nil
    end
  end

  defp markdown_table(headers, rows) do
    [
      "| #{Enum.join(headers, " | ")} |",
      "|#{Enum.map_join(headers, "|", fn _ -> "---" end)}|",
      Enum.map_join(rows, "\n", fn row -> "| #{Enum.join(row, " | ")} |" end)
    ]
    |> Enum.join("\n")
  end

  defp md_cell(value) do
    value
    |> to_string()
    |> String.replace("|", "\\|")
    |> String.replace("\n", "<br>")
  end

  defp fenced_block(content, language) do
    ["````#{language}", content || "", "````"]
    |> Enum.join("\n")
  end

  defp render_command_result(command, result_excerpt) do
    cond do
      low_value_command_output?(command) ->
        "_Inspection or git output omitted; re-run locally if you need the raw output._"

      result_excerpt ->
        result_excerpt
        |> compact_command_output()
        |> then(fn text ->
          if text in [nil, ""] do
            "_No structured output captured._"
          else
            fenced_block(text, "text")
          end
        end)

      true ->
        "_No structured output captured._"
    end
  end

  defp compact_command_output(nil), do: nil

  defp compact_command_output(text) do
    text
    |> String.split("\n")
    |> Enum.reject(fn line ->
      String.starts_with?(line, "Exit code:") || String.starts_with?(line, "Wall time:")
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp display_path(nil, _relative_to), do: nil

  defp display_path(path, nil), do: path

  defp display_path(path, relative_to) do
    if String.starts_with?(path, relative_to) do
      Path.relative_to(path, relative_to)
    else
      path
    end
  end

  defp format_read_target(path, nil), do: path

  defp format_read_target(path, read_span) do
    if String.starts_with?(read_span, "last ") do
      "#{path} (#{read_span})"
    else
      "#{path}:#{read_span}"
    end
  end

  defp truncate_text(nil, _max_chars), do: nil

  defp truncate_text(text, max_chars)
       when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "\n\n[truncated to #{max_chars} characters]"
    else
      text
    end
  end

  defp truncate_inline(nil, _max_chars), do: nil

  defp truncate_inline(text, max_chars)
       when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "…"
    else
      text
    end
  end

  defp inline_sentence(nil), do: "not captured"

  defp inline_sentence(text) do
    text
    |> String.replace("\n", " ")
    |> String.trim()
    |> truncate_inline(180)
    |> then(&"`#{&1}`")
  end

  defp format_sequence_range(%{started_sequence: start_seq, completed_sequence: end_seq})
       when is_integer(start_seq) and is_integer(end_seq) and start_seq != end_seq do
    "#{start_seq}-#{end_seq}"
  end

  defp format_sequence_range(%{started_sequence: start_seq}) when is_integer(start_seq),
    do: Integer.to_string(start_seq)

  defp format_sequence_range(%{sequence: sequence}) when is_integer(sequence),
    do: Integer.to_string(sequence)

  defp format_sequence_range(_value), do: "unknown"

  defp format_timestamp(nil), do: "unknown"
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(value), do: to_string(value)

  defp write_action_phrase("created"), do: "Created file"
  defp write_action_phrase("directory_created"), do: "Created directory"
  defp write_action_phrase("deleted"), do: "Deleted"
  defp write_action_phrase("renamed"), do: "Renamed or moved"
  defp write_action_phrase("modified"), do: "Updated"
  defp write_action_phrase("written"), do: "Updated"

  defp write_action_phrase(action),
    do: action |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp low_value_command_output?(command) do
    command.command_class in ["inspection", "version_control", "git_commit"] ||
      git_command_only?(command.command)
  end

  defp git_command_only?(command) when is_binary(command) do
    fragments = split_shell_fragments(command)

    fragments != [] &&
      Enum.all?(fragments, fn fragment ->
        String.starts_with?(fragment, "git ")
      end)
  end

  defp git_command_only?(_command), do: false

  defp extract_commit_messages(command) when is_binary(command) do
    command
    |> split_shell_fragments()
    |> Enum.flat_map(&extract_commit_message_from_fragment/1)
    |> Enum.uniq()
  end

  defp extract_commit_messages(_command), do: []

  defp extract_commit_message_from_fragment(fragment) do
    case OptionParser.split(fragment) do
      ["git", "commit" | args] ->
        case parse_commit_message_args(args, []) |> Enum.reverse() do
          [] -> []
          messages -> [Enum.join(messages, "\n\n")]
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp parse_commit_message_args([], messages), do: messages

  defp parse_commit_message_args(["-m", message | rest], messages),
    do: parse_commit_message_args(rest, [message | messages])

  defp parse_commit_message_args(["--message", message | rest], messages),
    do: parse_commit_message_args(rest, [message | messages])

  defp parse_commit_message_args([<<"-m", message::binary>> | rest], messages)
       when byte_size(message) > 0,
       do: parse_commit_message_args(rest, [message | messages])

  defp parse_commit_message_args([<<"--message=", message::binary>> | rest], messages),
    do: parse_commit_message_args(rest, [message | messages])

  defp parse_commit_message_args([_arg | rest], messages),
    do: parse_commit_message_args(rest, messages)

  defp split_shell_fragments(command) do
    command
    |> String.split(["\n", "&&", ";"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp transcript_sort_key(entry) do
    {Map.get(entry, :sequence, 0), Map.get(entry, :sort_offset, 0),
     transcript_role_order(entry.role)}
  end

  defp transcript_role_order(:user), do: 0
  defp transcript_role_order(:assistant), do: 1
  defp transcript_role_order(:commit), do: 2
  defp transcript_role_order(_other), do: 3

  defp yaml_scalar(nil), do: "null"
  defp yaml_scalar(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  defp yaml_scalar(value) when is_number(value), do: to_string(value)
  defp yaml_scalar(value) when is_atom(value), do: yaml_scalar(to_string(value))
  defp yaml_scalar(value) when is_binary(value), do: Jason.encode!(value)
  defp yaml_scalar(value), do: Jason.encode!(inspect(value))

  defp normalize_agent(nil), do: nil
  defp normalize_agent(agent) when is_atom(agent), do: agent

  defp normalize_agent(agent) when is_binary(agent) do
    case String.downcase(agent) do
      "copilot" -> :copilot
      "claude" -> :claude
      "codex" -> :codex
      "gemini" -> :gemini
      _ -> nil
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
