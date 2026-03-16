defmodule CopilotLv.SessionHandoff.Extractor do
  @moduledoc false

  @redundant_codex_event_msg_types ~w(user_message agent_message agent_reasoning)
  @file_path_keys ~w(path file_path filePath target_path targetPath destination destination_path output_path)

  def extract(session, events) do
    case session.agent do
      :claude -> extract_claude(session, events)
      :codex -> extract_codex(session, events)
      :gemini -> extract_gemini(session, events)
      _ -> extract_copilot(session, events)
    end
  end

  defp extract_copilot(session, events) do
    initial_state = %{
      prompts: [],
      assistant_outputs: [],
      operations: [],
      pending_tools: %{},
      current_assistant: nil
    }

    events
    |> Enum.reduce(initial_state, fn event, state ->
      state =
        if event.type == "assistant.message", do: state, else: flush_current_assistant(state)

      case event.type do
        "user.message" ->
          add_prompt(state, event.sequence, event.timestamp, map_get(event.data, "content"))

        "assistant.message" ->
          append_copilot_assistant(state, event)

        "tool.execution_start" ->
          add_tool_call(
            state,
            session,
            event,
            map_get(event.data, "toolName"),
            map_get(event.data, "arguments"),
            map_get(event.data, "toolCallId")
          )

        "tool.execution_complete" ->
          complete_tool_call(
            state,
            map_get(event.data, "toolCallId"),
            event.sequence,
            normalize_result_text(map_get(event.data, "result")),
            map_get(event.data, "success"),
            normalize_result_text(map_get(event.data, "error")),
            event.data
          )

        _ ->
          state
      end
    end)
    |> flush_current_assistant()
    |> finalize_pending_tools()
    |> finalize_extraction()
  end

  defp extract_claude(session, events) do
    initial_state = %{prompts: [], assistant_outputs: [], operations: [], pending_tools: %{}}

    events
    |> Enum.reduce(initial_state, fn event, state ->
      case event.type do
        "user" ->
          state = complete_claude_tool_results(state, event)
          add_prompt(state, event.sequence, event.timestamp, claude_user_text(event.data))

        "assistant" ->
          {text, tool_calls} = claude_assistant_payload(event.data)

          state =
            add_assistant_output(state, event.sequence, event.sequence, event.timestamp, text)

          Enum.reduce(tool_calls, state, fn %{id: id, name: name, input: input}, acc ->
            add_tool_call(acc, session, event, name, input, id)
          end)

        _ ->
          state
      end
    end)
    |> finalize_pending_tools()
    |> finalize_extraction()
  end

  defp extract_codex(session, events) do
    initial_state = %{prompts: [], assistant_outputs: [], operations: [], pending_tools: %{}}

    events
    |> Enum.reduce(initial_state, fn event, state ->
      case event.type do
        "response_item" ->
          payload = map_get(event.data, "payload") || %{}
          payload_type = map_get(payload, "type")
          role = map_get(payload, "role")

          cond do
            role == "user" ->
              add_prompt(state, event.sequence, event.timestamp, codex_user_text(payload))

            role == "assistant" ->
              add_assistant_output(
                state,
                event.sequence,
                event.sequence,
                event.timestamp,
                codex_assistant_text(payload)
              )

            payload_type in ["function_call", "custom_tool_call"] ->
              add_tool_call(
                state,
                session,
                event,
                map_get(payload, "name") || map_get(payload, "function"),
                normalize_tool_arguments(map_get(payload, "arguments")),
                map_get(payload, "call_id") || map_get(payload, "id")
              )

            payload_type in ["function_call_output", "custom_tool_call_output"] ->
              complete_tool_call(
                state,
                map_get(payload, "call_id") || map_get(payload, "id"),
                event.sequence,
                normalize_result_text(map_get(payload, "output")),
                true,
                nil,
                payload
              )

            true ->
              state
          end

        "event_msg" ->
          if redundant_codex_event_msg?(event.data), do: state, else: state

        _ ->
          state
      end
    end)
    |> finalize_pending_tools()
    |> finalize_extraction()
  end

  defp extract_gemini(session, events) do
    initial_state = %{prompts: [], assistant_outputs: [], operations: [], pending_tools: %{}}

    events
    |> Enum.reduce(initial_state, fn event, state ->
      case event.type do
        "user" ->
          add_prompt(
            state,
            event.sequence,
            event.timestamp,
            normalize_text_content(event.data["content"])
          )

        type when type in ["assistant", "gemini"] ->
          state =
            add_assistant_output(
              state,
              event.sequence,
              event.sequence,
              event.timestamp,
              gemini_assistant_text(event.data)
            )

          Enum.reduce(map_get(event.data, "toolCalls") || [], state, fn tool_call, acc ->
            tool_name = map_get(tool_call, "name") || map_get(tool_call, "toolName")
            tool_input = map_get(tool_call, "args") || map_get(tool_call, "input") || %{}
            call_id = map_get(tool_call, "id") || "gemini-call-#{event.sequence}"
            status = map_get(tool_call, "status")

            ops = classify_tool_call(session, tool_name, tool_input, event, call_id)

            completed_ops =
              Enum.map(ops, fn op ->
                Map.merge(op, %{
                  completed_sequence: event.sequence,
                  success: status != "error",
                  error:
                    if(status == "error",
                      do: normalize_result_text(map_get(tool_call, "error")),
                      else: nil
                    ),
                  result_excerpt: normalize_result_text(extract_gemini_tool_output(tool_call))
                })
              end)

            %{acc | operations: completed_ops ++ acc.operations}
          end)

        _ ->
          state
      end
    end)
    |> finalize_extraction()
  end

  defp append_copilot_assistant(state, event) do
    chunk =
      map_get(event.data, "chunkContent") ||
        map_get(event.data, "content") ||
        ""

    if blank?(chunk) do
      state
    else
      current =
        state.current_assistant ||
          %{
            sequence_start: event.sequence,
            sequence_end: event.sequence,
            timestamp: event.timestamp,
            text: ""
          }

      %{
        state
        | current_assistant: %{
            current
            | sequence_end: event.sequence,
              text: current.text <> chunk
          }
      }
    end
  end

  defp flush_current_assistant(%{current_assistant: nil} = state), do: state

  defp flush_current_assistant(state) do
    current = state.current_assistant

    state
    |> add_assistant_output(
      current.sequence_start,
      current.sequence_end,
      current.timestamp,
      String.trim(current.text)
    )
    |> Map.put(:current_assistant, nil)
  end

  defp add_prompt(state, _sequence, _timestamp, text) when text in [nil, ""], do: state

  defp add_prompt(state, sequence, timestamp, text) do
    if blank?(text) do
      state
    else
      prompt = %{sequence: sequence, timestamp: timestamp, text: String.trim(text)}
      %{state | prompts: [prompt | state.prompts]}
    end
  end

  defp add_assistant_output(state, _start_sequence, _end_sequence, _timestamp, text)
       when text in [nil, ""] do
    state
  end

  defp add_assistant_output(state, start_sequence, end_sequence, timestamp, text) do
    if blank?(text) do
      state
    else
      output = %{
        sequence_start: start_sequence,
        sequence_end: end_sequence,
        timestamp: timestamp,
        text: String.trim(text)
      }

      %{state | assistant_outputs: [output | state.assistant_outputs]}
    end
  end

  defp complete_claude_tool_results(state, event) do
    event.data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.reduce(state, fn
      %{"type" => "tool_result", "tool_use_id" => tool_use_id} = block, acc ->
        result = normalize_result_text(map_get(block, "content"))

        complete_tool_call(
          acc,
          tool_use_id,
          event.sequence,
          result,
          !tool_result_error?(block, event.data),
          if(tool_result_error?(block, event.data), do: result),
          block
        )

      _other, acc ->
        acc
    end)
  end

  defp tool_result_error?(block, event_data) do
    map_get(block, "is_error") == true ||
      get_in(event_data, ["toolUseResult", "is_error"]) == true
  end

  defp claude_user_text(data) do
    case get_in(data, ["message", "content"]) do
      content when is_binary(content) ->
        content

      content when is_list(content) ->
        content
        |> Enum.flat_map(fn
          %{"type" => "text", "text" => text} when is_binary(text) -> [text]
          _ -> []
        end)
        |> Enum.join("\n")
        |> String.trim()
        |> blank_to_nil()

      _ ->
        nil
    end
  end

  defp claude_assistant_payload(data) do
    content = get_in(data, ["message", "content"])

    if is_list(content) do
      text =
        content
        |> Enum.flat_map(fn
          %{"type" => "text", "text" => text} when is_binary(text) -> [text]
          _ -> []
        end)
        |> Enum.join("\n\n")
        |> String.trim()
        |> blank_to_nil()

      tool_calls =
        Enum.flat_map(content, fn
          %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
            [%{id: id, name: name, input: input || %{}}]

          _ ->
            []
        end)

      {text, tool_calls}
    else
      {nil, []}
    end
  end

  defp codex_user_text(payload) do
    text =
      payload
      |> map_get("content")
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"type" => "input_text", "text" => text} when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("\n")
      |> String.trim()

    cond do
      text == "" -> nil
      String.starts_with?(text, ["#", "<"]) -> nil
      true -> text
    end
  end

  defp codex_assistant_text(payload) do
    payload
    |> map_get("content")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> [text]
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n\n")
    |> String.trim()
    |> blank_to_nil()
  end

  defp gemini_assistant_text(data) do
    [
      normalize_text_content(map_get(data, "content")),
      normalize_text_content(map_get(data, "text"))
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> blank_to_nil()
  end

  defp add_tool_call(state, session, event, tool_name, arguments, call_id) do
    ops =
      classify_tool_call(session, tool_name, normalize_tool_arguments(arguments), event, call_id)

    cond do
      ops == [] ->
        state

      blank?(call_id) ->
        %{state | operations: ops ++ state.operations}

      true ->
        %{state | pending_tools: Map.put(state.pending_tools, call_id, ops)}
    end
  end

  defp complete_tool_call(state, call_id, _sequence, _result, _success, _error, _raw)
       when call_id in [nil, ""] do
    state
  end

  defp complete_tool_call(state, call_id, sequence, result_text, success, error_text, raw) do
    case Map.pop(state.pending_tools, call_id) do
      {nil, _pending_tools} ->
        state

      {ops, pending_tools} ->
        completed_ops =
          Enum.map(ops, fn op ->
            Map.merge(op, %{
              completed_sequence: sequence,
              result_excerpt: result_text,
              success: success,
              error: error_text,
              raw: Map.put(op.raw, "completion", raw)
            })
          end)

        %{state | pending_tools: pending_tools, operations: completed_ops ++ state.operations}
    end
  end

  defp finalize_pending_tools(state) do
    pending_ops = state.pending_tools |> Map.values() |> List.flatten()
    %{state | operations: pending_ops ++ state.operations, pending_tools: %{}}
  end

  defp finalize_extraction(state) do
    %{
      prompts: Enum.reverse(state.prompts),
      assistant_outputs: Enum.reverse(state.assistant_outputs),
      operations:
        state.operations
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&operation_sort_key/1)
    }
  end

  defp operation_sort_key(operation) do
    {operation.started_sequence || operation.completed_sequence || 0, operation.tool || ""}
  end

  defp classify_tool_call(session, tool_name, arguments, event, call_id) do
    tool = tool_name |> to_string() |> blank_to_nil()
    normalized_tool = tool |> to_string() |> String.downcase()

    base = %{
      kind: :other,
      action: nil,
      tool: tool,
      agent: session.agent,
      started_sequence: event.sequence,
      completed_sequence: nil,
      timestamp: event.timestamp,
      path: nil,
      paths: [],
      read_span: nil,
      command: nil,
      workdir: session.cwd,
      summary: nil,
      result_excerpt: nil,
      success: nil,
      error: nil,
      command_class: nil,
      confidence: :structured,
      raw: %{
        "tool_call_id" => call_id,
        "tool_name" => tool,
        "arguments" => arguments,
        "event_type" => event.type
      }
    }

    case normalized_tool do
      "view" ->
        single_path_read(base, arguments)

      "read" ->
        single_path_read(base, arguments)

      "edit" ->
        single_path_write(base, arguments, "modified")

      "multiedit" ->
        single_path_write(base, arguments, "modified")

      "write" ->
        single_path_write(base, arguments, "written")

      "apply_patch" ->
        parse_patch_operations(extract_patch_text(arguments), base)

      "bash" ->
        shell_operations(base, arguments, session.cwd)

      "shell_command" ->
        shell_operations(base, arguments, session.cwd)

      "rg" ->
        [search_operation(base, arguments)]

      "grep" ->
        [search_operation(base, arguments)]

      "glob" ->
        [search_operation(base, arguments)]

      "ls" ->
        [search_operation(base, arguments)]

      "report_intent" ->
        [
          Map.merge(base, %{
            kind: :intent,
            summary: map_get(arguments, "intent") || inspect(arguments)
          })
        ]

      _ ->
        maybe_shell_like_operations(base, arguments, session.cwd)
    end
  end

  defp single_path_read(base, arguments) do
    case extract_primary_path(arguments) do
      nil ->
        []

      path ->
        [
          Map.merge(base, %{
            kind: :file_read,
            path: path,
            paths: [path],
            read_span: extract_read_span(arguments)
          })
        ]
    end
  end

  defp single_path_write(base, arguments, action) do
    case extract_primary_path(arguments) do
      nil -> []
      path -> [Map.merge(base, %{kind: :file_write, action: action, path: path, paths: [path]})]
    end
  end

  defp search_operation(base, arguments) do
    pattern =
      map_get(arguments, "pattern") || map_get(arguments, "query") || map_get(arguments, "glob")

    path = map_get(arguments, "path")

    summary =
      [pattern && "pattern=#{pattern}", path && "path=#{path}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")
      |> blank_to_nil()

    Map.merge(base, %{
      kind: :search,
      path: path,
      paths: List.wrap(path),
      summary: summary || inspect(arguments)
    })
  end

  defp maybe_shell_like_operations(base, arguments, cwd) do
    command = map_get(arguments, "command") || map_get(arguments, "cmd")

    if blank?(command) do
      []
    else
      shell_operations(base, arguments, cwd)
    end
  end

  defp shell_operations(base, arguments, cwd) do
    command = map_get(arguments, "command") || map_get(arguments, "cmd")

    if blank?(command) do
      []
    else
      workdir = map_get(arguments, "workdir") || map_get(arguments, "cwd") || cwd
      description = map_get(arguments, "description")

      command_op =
        Map.merge(base, %{
          kind: :command,
          command: command,
          workdir: workdir,
          summary: description,
          command_class: classify_command(command)
        })

      [command_op | infer_shell_operations(command, base, workdir)]
    end
  end

  defp infer_shell_operations(command, base, workdir) do
    command
    |> split_command_fragments()
    |> Enum.flat_map(fn fragment -> infer_shell_fragment(fragment, base, workdir) end)
  end

  defp infer_shell_fragment(fragment, base, workdir) do
    line = String.trim(fragment)

    inferred_base = %{
      base
      | confidence: :inferred,
        raw: Map.put(base.raw, "shell_fragment", line),
        workdir: workdir
    }

    search_ops =
      if Regex.match?(~r/\b(rg|grep|find|fd)\b/, line) do
        [Map.merge(inferred_base, %{kind: :search, summary: line})]
      else
        []
      end

    read_ops = inferred_read_operations(line, inferred_base)

    write_ops =
      line
      |> inferred_write_paths()
      |> Enum.map(fn {action, path} ->
        Map.merge(inferred_base, %{kind: :file_write, action: action, path: path, paths: [path]})
      end)

    move_ops =
      case Regex.run(
             ~r/\b(cp|mv)\s+(?:-[^\s]+\s+)*(['"]?)([^'"\s|&;]+)\2\s+(['"]?)([^'"\s|&;]+)\4/,
             line
           ) do
        [_, command_name, _, source, _, destination] ->
          [
            Map.merge(inferred_base, %{kind: :file_read, path: source, paths: [source]}),
            Map.merge(inferred_base, %{
              kind: :file_write,
              action: if(command_name == "mv", do: "renamed", else: "created"),
              path: destination,
              paths: [destination]
            })
          ]

        _ ->
          []
      end

    search_ops ++ read_ops ++ write_ops ++ move_ops
  end

  defp inferred_write_paths(line) do
    redirections =
      Regex.scan(~r/(?:>>|>)\s*(['"]?)([^'"\s|&;]+)\1/, line)
      |> Enum.map(fn [_, _, path] -> {"written", path} end)

    tees =
      Regex.scan(~r/\btee\s+(?:-a\s+)?(['"]?)([^'"\s|&;]+)\1/, line)
      |> Enum.map(fn [_, _, path] -> {"written", path} end)

    mkdirs =
      Regex.scan(~r/\bmkdir\s+(?:-p\s+)?(['"]?)([^'"\s|&;]+)\1/, line)
      |> Enum.map(fn [_, _, path] -> {"directory_created", path} end)

    touches =
      Regex.scan(~r/\btouch\s+(['"]?)([^'"\s|&;]+)\1/, line)
      |> Enum.map(fn [_, _, path] -> {"created", path} end)

    removals =
      Regex.scan(~r/\brm\s+(?:-[^\s]+\s+)*(['"]?)([^'"\s|&;]+)\1/, line)
      |> Enum.map(fn [_, _, path] -> {"deleted", path} end)

    redirections ++ tees ++ mkdirs ++ touches ++ removals
  end

  defp inferred_read_operations(line, base) do
    sed_reads =
      Regex.scan(~r/\bsed\s+-n\s+['"]?(\d+),(\d+)p['"]?\s+(['"]?)([^'"\s|&;]+)\3/, line)
      |> Enum.map(fn [_, start_line, end_line, _, path] ->
        build_read_operation(base, path, "#{start_line}-#{end_line}")
      end)

    head_reads =
      Regex.scan(~r/\bhead(?:\s+-n\s+(\d+))?(?:\s+-[^\s]+\s+)*(['"]?)([^'"\s|&;]+)\2/, line)
      |> Enum.map(fn [_, count, _, path] ->
        span = if blank?(count), do: nil, else: "1-#{count}"
        build_read_operation(base, path, span)
      end)

    tail_reads =
      Regex.scan(~r/\btail(?:\s+-n\s+(\d+))?(?:\s+-[^\s]+\s+)*(['"]?)([^'"\s|&;]+)\2/, line)
      |> Enum.map(fn [_, count, _, path] ->
        span = if blank?(count), do: nil, else: "last #{count} lines"
        build_read_operation(base, path, span)
      end)

    cat_reads =
      Regex.scan(~r/\bcat\s+(['"]?)([^'"\s|&;]+)\1/, line)
      |> Enum.map(fn [_, _, path] -> build_read_operation(base, path, nil) end)

    sed_reads ++ head_reads ++ tail_reads ++ cat_reads
  end

  defp build_read_operation(base, path, read_span) do
    Map.merge(base, %{kind: :file_read, path: path, paths: [path], read_span: read_span})
  end

  defp parse_patch_operations(nil, _base), do: []

  defp parse_patch_operations(patch, base) when is_binary(patch) do
    patch
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      cond do
        String.starts_with?(line, "*** Add File: ") ->
          path = String.replace_prefix(line, "*** Add File: ", "")
          [Map.merge(base, %{kind: :file_write, action: "created", path: path, paths: [path]})]

        String.starts_with?(line, "*** Update File: ") ->
          path = String.replace_prefix(line, "*** Update File: ", "")
          [Map.merge(base, %{kind: :file_write, action: "modified", path: path, paths: [path]})]

        String.starts_with?(line, "*** Delete File: ") ->
          path = String.replace_prefix(line, "*** Delete File: ", "")
          [Map.merge(base, %{kind: :file_delete, action: "deleted", path: path, paths: [path]})]

        String.starts_with?(line, "*** Move to: ") ->
          path = String.replace_prefix(line, "*** Move to: ", "")
          [Map.merge(base, %{kind: :file_write, action: "renamed", path: path, paths: [path]})]

        true ->
          []
      end
    end)
    |> Enum.uniq_by(&{&1.kind, &1.action, &1.path})
  end

  defp normalize_tool_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> decoded
      _ -> arguments
    end
  end

  defp normalize_tool_arguments(arguments), do: arguments

  defp extract_patch_text(arguments) when is_binary(arguments), do: arguments

  defp extract_patch_text(arguments) when is_map(arguments) do
    map_get(arguments, "patch") || map_get(arguments, "content") || map_get(arguments, "diff")
  end

  defp extract_patch_text(_arguments), do: nil

  defp extract_primary_path(arguments) when is_map(arguments) do
    Enum.find_value(@file_path_keys, fn key -> map_get(arguments, key) end)
  end

  defp extract_primary_path(_arguments), do: nil

  defp extract_read_span(arguments) when is_map(arguments) do
    cond do
      span = normalize_view_range(map_get(arguments, "view_range")) ->
        span

      span = normalize_view_range(map_get(arguments, "viewRange")) ->
        span

      span =
          normalize_line_range(
            map_get(arguments, "start_line") || map_get(arguments, "startLine"),
            map_get(arguments, "end_line") || map_get(arguments, "endLine")
          ) ->
        span

      true ->
        nil
    end
  end

  defp extract_read_span(_arguments), do: nil

  defp normalize_view_range([start_line, end_line]),
    do: normalize_line_range(start_line, end_line)

  defp normalize_view_range(_value), do: nil

  defp normalize_line_range(start_line, end_line) do
    start_line = parse_integer(start_line)
    end_line = parse_integer(end_line)

    cond do
      is_integer(start_line) && end_line == -1 ->
        "#{start_line}-end"

      is_integer(start_line) && is_integer(end_line) && start_line == end_line ->
        Integer.to_string(start_line)

      is_integer(start_line) && is_integer(end_line) ->
        "#{start_line}-#{end_line}"

      is_integer(start_line) ->
        Integer.to_string(start_line)

      true ->
        nil
    end
  end

  defp classify_command(command) when not is_binary(command), do: "command"

  defp classify_command(command) do
    command = String.downcase(command)

    cond do
      Regex.match?(~r/\bgit commit\b/, command) ->
        "git_commit"

      Regex.match?(
        ~r/\b(mix test|mix precommit|npm test|pnpm test|yarn test|go test|cargo test|pytest|rspec)\b/,
        command
      ) ->
        "test_run"

      Regex.match?(
        ~r/\b(mix phx\.server|iex -s mix phx\.server|npm run dev|pnpm dev|yarn dev|docker compose up)\b/,
        command
      ) ->
        "server_or_daemon"

      Regex.match?(
        ~r/\b(mix compile|npm run build|pnpm build|yarn build|cargo build|go build)\b/,
        command
      ) ->
        "build"

      Regex.match?(~r/\b(python|python3|node|ruby|perl|mix run|elixir)\b/, command) ->
        "code_execution"

      Regex.match?(~r/\bgit\b/, command) ->
        "version_control"

      Regex.match?(~r/\b(rg|grep|ls|cat|head|tail|find|fd|sed -n)\b/, command) ->
        "inspection"

      true ->
        "command"
    end
  end

  defp split_command_fragments(command) do
    String.split(command, ["\n", "&&", ";"], trim: true)
  end

  defp normalize_result_text(nil), do: nil
  defp normalize_result_text(""), do: nil

  defp normalize_result_text(%{"content" => content}), do: normalize_result_text(content)

  defp normalize_result_text(%{"stdout" => stdout, "stderr" => stderr}) do
    [stdout, stderr]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
    |> blank_to_nil()
  end

  defp normalize_result_text(%{"output" => output}), do: normalize_result_text(output)

  defp normalize_result_text(result) when is_binary(result), do: result

  defp normalize_result_text(result) when is_list(result) do
    result
    |> Enum.map(&normalize_result_text/1)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
    |> blank_to_nil()
  end

  defp normalize_result_text(result) when is_map(result), do: Jason.encode!(result, pretty: true)
  defp normalize_result_text(result), do: inspect(result)

  defp normalize_text_content(nil), do: nil
  defp normalize_text_content(text) when is_binary(text), do: blank_to_nil(String.trim(text))

  defp normalize_text_content(parts) when is_list(parts) do
    parts
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
    |> String.trim()
    |> blank_to_nil()
  end

  defp normalize_text_content(_other), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      :error -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp extract_gemini_tool_output(tool_call) do
    map_get(tool_call, "output") ||
      get_in(tool_call, ["functionResponse", "response"]) ||
      get_in(tool_call, ["functionResponse", "output"])
  end

  defp redundant_codex_event_msg?(data) do
    map_get(data, "payload")
    |> map_get("type")
    |> then(&(&1 in @redundant_codex_event_msg_types))
  end

  defp map_get(nil, _key), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, Atom.to_string(key))
    end
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp map_get(_other, _key), do: nil

  defp blank?(value), do: blank_to_nil(value) == nil
  defp blank_to_nil(value) when value in [nil, ""], do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
