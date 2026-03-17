defmodule CopilotLvWeb.SessionLive.Show do
  use CopilotLvWeb, :live_view

  import CopilotLvWeb.FileTreePicker

  alias CopilotLv.{SessionHandoff, SessionServer, SessionRegistry}
  alias CopilotLv.Sessions.{Checkpoint, SessionArtifact}
  alias Jido.ToolRenderers.Adapters.CopilotLv, as: EventAdapter
  alias Jido.ToolRenderers.SessionViewer.{Rich, Terminal}
  alias Phoenix.PubSub

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Check if session exists in DB
    case SessionRegistry.get_session(id) do
      {:ok, db_session} ->
        active = SessionRegistry.session_exists?(id)

        if connected?(socket) && active do
          PubSub.subscribe(CopilotLv.PubSub, SessionServer.topic(id))
        end

        # Get live state if active, otherwise use DB data
        {status, model, cwd, usage} =
          if active do
            info = SessionServer.get_state(id)
            {info.status, info.model, info.cwd, info.usage}
          else
            usage_entries =
              CopilotLv.Sessions.UsageEntry
              |> Ash.Query.for_read(:for_session, %{session_id: id})
              |> Ash.read!()
              |> Enum.map(fn u ->
                %{
                  model: u.model,
                  input_tokens: u.input_tokens,
                  output_tokens: u.output_tokens,
                  cache_read_tokens: u.cache_read_tokens,
                  cache_write_tokens: u.cache_write_tokens,
                  cost: u.cost,
                  initiator: u.initiator,
                  duration_ms: u.duration_ms
                }
              end)

            {db_session.status, db_session.model, db_session.cwd, usage_entries}
          end

        models =
          Jido.GHCopilot.Models.all()
          |> Enum.sort_by(fn {name, _id, _multiplier} -> String.downcase(name) end)

        # Load historic events from DB
        db_events =
          CopilotLv.Sessions.Event
          |> Ash.Query.for_read(:for_session, %{session_id: id})
          |> Ash.read!()
          |> Enum.map(fn e ->
            data = e.data || %{}

            # Normalize: new Copilot parser stores full event as data (has nested "data" key).
            # Old Sync stored only the inner data. Unwrap for consistency.
            data =
              if db_session.agent == :copilot && is_map(data["data"]) &&
                   data["type"] == e.event_type do
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

        checkpoints =
          Checkpoint
          |> Ash.Query.for_read(:for_session, %{session_id: id})
          |> Ash.read!()
          |> build_checkpoint_entries(db_events)

        artifacts =
          SessionArtifact
          |> Ash.Query.for_read(:for_session, %{session_id: id})
          |> Ash.read!()
          |> sort_artifacts()

        # Pre-process events to accumulate assistant messages for markdown rendering
        {stream_events, _, _} =
          case db_session.agent do
            :claude -> build_claude_stream_events(db_events)
            :codex -> build_codex_stream_events(db_events)
            :gemini -> build_gemini_stream_events(db_events)
            :pi -> build_pi_stream_events(db_events)
            _ -> build_stream_events(db_events)
          end

        socket =
          socket
          |> assign(:session_id, id)
          |> assign(:model, model)
          |> assign(:cwd, cwd)
          |> assign(:status, status)
          |> assign(:usage, usage)
          |> assign(:agent, db_session.agent || :copilot)
          |> assign(:hostname, db_session.hostname)
          |> assign(:prompt, "")
          |> assign(:models, models)
          |> assign(:active, active)
          |> assign(:starred, db_session.starred)
          |> assign(:assistant_text, "")
          |> assign(:assistant_msg_id, nil)
          |> assign(:pending_tools, %{})
          |> assign(:tool_group_events, [])
          |> assign(:tool_group_id, nil)
          |> assign(:ask_user_request, nil)
          |> assign(:ask_user_freeform, "")
          |> assign(:file_suggestions, [])
          |> assign(:selected_files, [])
          |> assign(:resolved_files, %{})
          |> assign(:file_query, "")
          |> assign(:file_picker_index, -1)
          |> assign(:view_mode, :rich)
          |> assign(:inspector_open, true)
          |> assign(:file_viewer, nil)
          |> assign(:git_root, db_session.git_root)
          |> assign(:pasted_contents, [])
          |> assign(:inspector_tab, default_inspector_tab(checkpoints, artifacts))
          |> assign(:checkpoints, checkpoints)
          |> assign(:selected_checkpoint_id, default_checkpoint_id(checkpoints))
          |> assign(:artifacts, artifacts)
          |> assign(:selected_artifact_id, default_artifact_id(artifacts))
          |> assign(:terminal_events, stream_events)
          |> stream_configure(:events, dom_id: & &1.dom_id)
          |> stream(:events, stream_events)
          |> then(fn socket ->
            if connected?(socket), do: push_file_tokens(socket, stream_events), else: socket
          end)

        {:ok, socket}

      {:error, _} ->
        {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  # Internal/bookkeeping event types that should not appear in the conversation stream.
  @noise_event_types MapSet.new([
                       "session.truncation",
                       "session.start",
                       "session.model_change",
                       "session.compaction_start",
                       "session.compaction_complete",
                       "session.plan_changed",
                       "session.resume",
                       "session.shutdown",
                       "session.context_changed",
                       "session.mode_changed",
                       "session.workspace_file_changed",
                       "session.usage_info",
                       "file-history-snapshot",
                       "progress",
                       "queue-operation",
                       "compacted",
                       "custom-title",
                       "hook.start",
                       "hook.end",
                       "permission.requested",
                       "permission.completed",
                       "tool.user_requested",
                       "pending_messages.modified"
                     ])

  # Build stream events from raw DB events, accumulating assistant.message chunks
  # and merging tool.execution_start + tool.execution_complete into combined cards
  defp build_stream_events(events) do
    # State: {acc, text, msg_id, msg_index, pending}
    # msg_index tracks where the current assistant block lives in acc
    {flat, _text, _msg_id, _msg_idx, _pending} =
      events
      |> Enum.reject(fn e -> MapSet.member?(@noise_event_types, e.type) end)
      |> Enum.reduce({[], "", nil, nil, %{}}, fn event, {acc, text, msg_id, msg_idx, pending} ->
        case event.type do
          "assistant.message" ->
            chunk = event.data["chunkContent"] || event.data["content"] || ""
            new_text = text <> chunk
            new_id = msg_id || "assistant-msg-replay-#{System.unique_integer([:positive])}"

            block = %{
              type: "assistant.message.block",
              data: %{"content" => new_text},
              dom_id: new_id
            }

            {updated_acc, new_idx} =
              if msg_idx do
                {List.replace_at(acc, msg_idx, block), msg_idx}
              else
                {acc ++ [block], length(acc)}
              end

            {updated_acc, new_text, new_id, new_idx, pending}

          "tool.execution_start" ->
            tool_call_id = event.data["toolCallId"]
            dom_id = "tool-replay-#{tool_call_id || System.unique_integer([:positive])}"

            combined = %{
              type: "tool.combined",
              data: %{
                "toolName" => event.data["toolName"],
                "arguments" => event.data["arguments"],
                "toolCallId" => tool_call_id,
                "completed" => false
              },
              dom_id: dom_id
            }

            new_pending = Map.put(pending, tool_call_id, %{dom_id: dom_id, index: length(acc)})
            {acc ++ [combined], text, msg_id, msg_idx, new_pending}

          "tool.execution_complete" ->
            tool_call_id = event.data["toolCallId"]
            tool_info = Map.get(pending, tool_call_id)

            if tool_info do
              existing = Enum.at(acc, tool_info.index)

              updated = %{
                existing
                | data:
                    Map.merge(existing.data, %{
                      "completed" => true,
                      "success" => event.data["success"],
                      "result" => event.data["result"],
                      "error" => event.data["error"]
                    })
              }

              updated_acc = List.replace_at(acc, tool_info.index, updated)
              new_pending = Map.delete(pending, tool_call_id)
              {updated_acc, text, msg_id, msg_idx, new_pending}
            else
              {acc ++ [event], text, msg_id, msg_idx, pending}
            end

          t when t in ["assistant.turn_start", "user.message"] ->
            {acc ++ [event], "", nil, nil, pending}

          _ ->
            {acc ++ [event], text, msg_id, msg_idx, pending}
        end
      end)

    # Group consecutive non-message events into collapsible sections
    grouped = group_into_collapsible(flat)
    {grouped, "", nil}
  end

  # Only user messages break groups — everything else (tools, intents, intermediate
  # assistant messages, usage, turns) stays inside the collapsible group.
  defp group_into_collapsible(events) do
    {acc, current_group} =
      Enum.reduce(events, {[], []}, fn event, {acc, group} ->
        if event.type == "user.message" do
          acc = flush_tool_group_with_trailing_message(acc, group)
          {acc ++ [event], []}
        else
          {acc, group ++ [event]}
        end
      end)

    flush_tool_group_with_trailing_message(acc, current_group)
  end

  # Flush a group, pulling the last assistant.message.block out as a standalone event
  defp flush_tool_group_with_trailing_message(acc, []), do: acc

  defp flush_tool_group_with_trailing_message(acc, events) do
    # Find the index of the last assistant.message.block with non-empty content
    last_msg_idx =
      events
      |> Enum.with_index()
      |> Enum.filter(fn {e, _} ->
        e.type == "assistant.message.block" && String.trim(e.data["content"] || "") != ""
      end)
      |> List.last()

    case last_msg_idx do
      {msg, idx} ->
        group_events = List.delete_at(events, idx)
        acc = if group_events != [], do: flush_tool_group(acc, group_events), else: acc
        acc ++ [msg]

      nil ->
        flush_tool_group(acc, events)
    end
  end

  defp flush_tool_group(acc, []), do: acc

  defp flush_tool_group(acc, events) do
    tool_events = Enum.filter(events, &(&1.type == "tool.combined"))

    if tool_events == [] do
      # No tool calls — emit remaining visible events (messages, reasoning) as standalone items
      visible =
        Enum.filter(events, &(&1.type in ["assistant.message.block", "assistant.reasoning"]))

      acc ++ visible
    else
      tool_names = tool_events |> Enum.map(& &1.data["toolName"]) |> Enum.uniq()
      tool_count = length(tool_events)

      group = %{
        type: "tool.group",
        data: %{
          "events" => events,
          "tool_names" => tool_names,
          "tool_count" => tool_count
        },
        dom_id: "tool-group-#{System.unique_integer([:positive])}"
      }

      acc ++ [group]
    end
  end

  # ── Claude event processing ──

  defp build_claude_stream_events(events) do
    flat =
      events
      |> Enum.reject(fn e ->
        e.type in ["file-history-snapshot", "summary", "system"]
      end)
      |> Enum.flat_map(&claude_event_to_stream/1)
      |> merge_claude_tool_results()

    grouped = group_into_collapsible(flat)
    {grouped, "", nil}
  end

  # Merge tool.execution_complete into matching tool.combined events
  defp merge_claude_tool_results(events) do
    # Collect all tool outputs by call_id
    outputs =
      events
      |> Enum.filter(&(&1.type == "tool.execution_complete"))
      |> Map.new(&{&1.data["toolCallId"], &1.data})

    # Merge outputs into tool.combined events, drop standalone execution_completes
    Enum.flat_map(events, fn event ->
      case event.type do
        "tool.combined" ->
          case Map.get(outputs, event.data["toolCallId"]) do
            nil ->
              [event]

            output_data ->
              [
                %{
                  event
                  | data:
                      Map.merge(event.data, %{
                        "completed" => true,
                        "success" => output_data["success"],
                        "result" => output_data["result"],
                        "error" => output_data["error"]
                      })
                }
              ]
          end

        "tool.execution_complete" ->
          if Map.has_key?(outputs, event.data["toolCallId"]) &&
               Enum.any?(
                 events,
                 &(&1.type == "tool.combined" && &1.data["toolCallId"] == event.data["toolCallId"])
               ) do
            []
          else
            [event]
          end

        _ ->
          [event]
      end
    end)
  end

  defp claude_event_to_stream(%{type: "user", data: data} = event) do
    content = get_in(data, ["message", "content"])

    cond do
      # Tool result responses
      is_list(content) && Enum.any?(content, &(is_map(&1) && &1["type"] == "tool_result")) ->
        Enum.flat_map(content, fn
          %{"type" => "tool_result", "tool_use_id" => id} = block ->
            result = block["content"]
            # result can be a string or a list of content blocks
            result_text =
              cond do
                is_binary(result) ->
                  result

                is_list(result) ->
                  Enum.map_join(result, "\n", fn
                    %{"text" => t} when is_binary(t) -> t
                    other -> inspect(other)
                  end)

                true ->
                  inspect(result)
              end

            is_error =
              case block["is_error"] do
                true ->
                  true

                _ ->
                  case data["toolUseResult"] do
                    %{"is_error" => true} -> true
                    _ -> false
                  end
              end

            [
              %{
                type: "tool.execution_complete",
                data: %{
                  "toolCallId" => id,
                  "result" => result_text,
                  "success" => !is_error,
                  "error" => if(is_error, do: result_text)
                },
                dom_id: "claude-tool-result-#{id}"
              }
            ]

          _ ->
            []
        end)

      # Regular user message
      is_binary(content) ->
        [%{type: "user.message", data: %{"content" => content}, dom_id: event.dom_id}]

      is_list(content) ->
        text =
          content
          |> Enum.flat_map(fn
            %{"type" => "text", "text" => t} -> [t]
            _ -> []
          end)
          |> Enum.join("\n")

        if String.trim(text) != "" do
          [%{type: "user.message", data: %{"content" => text}, dom_id: event.dom_id}]
        else
          []
        end

      true ->
        []
    end
  end

  defp claude_event_to_stream(%{type: "assistant", data: data}) do
    content = get_in(data, ["message", "content"])

    if is_list(content) do
      content
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) and text != "" ->
          [
            %{
              type: "assistant.message.block",
              data: %{"content" => text},
              dom_id: "claude-text-#{System.unique_integer([:positive])}"
            }
          ]

        %{"type" => "thinking", "thinking" => thinking}
        when is_binary(thinking) and thinking != "" ->
          [
            %{
              type: "assistant.reasoning",
              data: %{"content" => thinking},
              dom_id: "claude-thinking-#{System.unique_integer([:positive])}"
            }
          ]

        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
          [
            %{
              type: "tool.combined",
              data: %{
                "toolName" => name,
                "toolCallId" => id,
                "arguments" => input,
                "completed" => false
              },
              dom_id: "claude-tool-#{id}"
            }
          ]

        _ ->
          []
      end)
    else
      []
    end
  end

  defp claude_event_to_stream(_event), do: []

  # ── Codex event processing ──

  defp build_codex_stream_events(events) do
    flat =
      events
      |> Enum.reject(fn e -> e.type in ["session_meta", "turn_context"] end)
      |> Enum.flat_map(&codex_event_to_stream/1)
      |> merge_codex_tool_results()

    grouped = group_into_collapsible(flat)
    {grouped, "", nil}
  end

  defp codex_event_to_stream(%{type: "response_item", data: data} = event) do
    payload = data["payload"] || %{}
    role = payload["role"]
    content = payload["content"]
    payload_type = payload["type"]

    cond do
      role == "user" && is_list(content) ->
        text =
          content
          |> Enum.flat_map(fn
            %{"type" => "input_text", "text" => t} when is_binary(t) -> [t]
            _ -> []
          end)
          |> Enum.join("\n")
          |> String.trim()

        # Skip system-injected messages
        if text != "" && !String.starts_with?(text, "#") && !String.starts_with?(text, "<") do
          [%{type: "user.message", data: %{"content" => text}, dom_id: event.dom_id}]
        else
          []
        end

      role == "assistant" && is_list(content) ->
        Enum.flat_map(content, fn
          %{"type" => "output_text", "text" => t} when is_binary(t) and t != "" ->
            [
              %{
                type: "assistant.message.block",
                data: %{"content" => t},
                dom_id: "codex-text-#{System.unique_integer([:positive])}"
              }
            ]

          %{"type" => "text", "text" => t} when is_binary(t) and t != "" ->
            [
              %{
                type: "assistant.message.block",
                data: %{"content" => t},
                dom_id: "codex-text-#{System.unique_integer([:positive])}"
              }
            ]

          _ ->
            []
        end)

      payload_type in ["function_call", "custom_tool_call"] ->
        name = payload["name"] || payload["function"] || "tool"
        call_id = payload["call_id"] || payload["id"]
        args = payload["arguments"]

        args_str =
          cond do
            is_binary(args) -> args
            is_map(args) -> Jason.encode!(args, pretty: true)
            true -> inspect(args)
          end

        [
          %{
            type: "tool.combined",
            data: %{
              "toolName" => name,
              "toolCallId" => call_id,
              "arguments" => args_str,
              "completed" => false
            },
            dom_id: "codex-tool-#{call_id || System.unique_integer([:positive])}"
          }
        ]

      payload_type in ["function_call_output", "custom_tool_call_output"] ->
        call_id = payload["call_id"] || payload["id"]
        output = payload["output"] || ""

        [
          %{
            type: "tool.execution_complete",
            data: %{
              "toolCallId" => call_id,
              "result" => if(is_binary(output), do: output, else: Jason.encode!(output)),
              "success" => true,
              "error" => nil
            },
            dom_id: "codex-tool-result-#{call_id || System.unique_integer([:positive])}"
          }
        ]

      payload_type == "reasoning" ->
        text = payload["text"] || payload["content"]

        if is_binary(text) && String.trim(text) != "" do
          [
            %{
              type: "assistant.reasoning",
              data: %{"content" => text},
              dom_id: "codex-reasoning-#{System.unique_integer([:positive])}"
            }
          ]
        else
          []
        end

      true ->
        []
    end
  end

  # The Codex CLI writes redundant event_msg entries (user_message, agent_message,
  # agent_reasoning) that duplicate data already present in response_item events.
  # These are filtered out during parsing in Codex.parse_session/1, so only
  # non-conversational event_msg subtypes (token_count, task_started, etc.) reach
  # here. None of those are rendered in the rich view.
  defp codex_event_to_stream(%{type: "event_msg", data: _data}), do: []

  defp codex_event_to_stream(_event), do: []

  defp merge_codex_tool_results(events) do
    # Collect all tool outputs by call_id
    outputs =
      events
      |> Enum.filter(&(&1.type == "tool.execution_complete"))
      |> Map.new(&{&1.data["toolCallId"], &1.data})

    # Merge outputs into tool.combined events, drop standalone execution_completes
    Enum.flat_map(events, fn event ->
      case event.type do
        "tool.combined" ->
          case Map.get(outputs, event.data["toolCallId"]) do
            nil ->
              [event]

            output_data ->
              [
                %{
                  event
                  | data:
                      Map.merge(event.data, %{
                        "completed" => true,
                        "success" => output_data["success"],
                        "result" => output_data["result"],
                        "error" => output_data["error"]
                      })
                }
              ]
          end

        "tool.execution_complete" ->
          # Drop if already merged into a tool.combined
          if Map.has_key?(outputs, event.data["toolCallId"]) &&
               Enum.any?(
                 events,
                 &(&1.type == "tool.combined" && &1.data["toolCallId"] == event.data["toolCallId"])
               ) do
            []
          else
            [event]
          end

        _ ->
          [event]
      end
    end)
  end

  # ── Gemini event processing ──

  defp build_gemini_stream_events(events) do
    flat =
      events
      |> Enum.reject(fn e -> e.type in ["session_meta", "info"] end)
      |> Enum.flat_map(&gemini_event_to_stream/1)

    grouped = group_into_collapsible(flat)
    {grouped, "", nil}
  end

  defp gemini_event_to_stream(%{type: "user", data: data} = event) do
    text = data["content"]

    if is_binary(text) && String.trim(text) != "" do
      [%{type: "user.message", data: %{"content" => text}, dom_id: event.dom_id}]
    else
      []
    end
  end

  defp gemini_event_to_stream(%{type: type, data: data} = _event)
       when type in ["assistant", "gemini"] do
    result = []

    # Thinking/thoughts
    result =
      case data["thoughts"] do
        thoughts when is_list(thoughts) and thoughts != [] ->
          thinking_text =
            Enum.map_join(thoughts, "\n\n", fn t ->
              subject = if is_binary(t["subject"]), do: "**#{t["subject"]}**: ", else: ""
              "#{subject}#{t["description"] || ""}"
            end)

          [
            %{
              type: "assistant.reasoning",
              data: %{"content" => thinking_text},
              dom_id: "gemini-thinking-#{System.unique_integer([:positive])}"
            }
            | result
          ]

        _ ->
          result
      end

    # Tool calls
    result =
      case data["toolCalls"] do
        calls when is_list(calls) and calls != [] ->
          tool_events =
            Enum.flat_map(calls, fn call ->
              name = call["name"] || call["toolName"] || "tool"
              args = call["args"] || call["input"] || %{}
              call_id = call["id"] || "gemini-call-#{System.unique_integer([:positive])}"

              # Extract output from nested functionResponse structure
              output = extract_gemini_tool_output(call)

              args_str =
                if is_map(args), do: Jason.encode!(args, pretty: true), else: inspect(args)

              [
                %{
                  type: "tool.combined",
                  data: %{
                    "toolName" => name,
                    "toolCallId" => call_id,
                    "arguments" => args_str,
                    "completed" => output != nil,
                    "success" => call["status"] != "error",
                    "result" => output || ""
                  },
                  dom_id: "gemini-tool-#{call_id}"
                }
              ]
            end)

          tool_events ++ result

        _ ->
          result
      end

    # Main content text
    result =
      case data["content"] do
        text when is_binary(text) and text != "" ->
          [
            %{
              type: "assistant.message.block",
              data: %{"content" => text},
              dom_id: "gemini-text-#{System.unique_integer([:positive])}"
            }
            | result
          ]

        _ ->
          result
      end

    Enum.reverse(result)
  end

  defp gemini_event_to_stream(_event), do: []

  defp extract_gemini_tool_output(call) do
    cond do
      # Direct output field
      is_binary(call["output"]) ->
        call["output"]

      # Nested functionResponse structure
      is_list(call["result"]) ->
        call["result"]
        |> Enum.flat_map(fn
          %{"functionResponse" => %{"response" => %{"output" => output}}}
          when is_binary(output) ->
            [output]

          %{"functionResponse" => %{"response" => resp}} when is_map(resp) ->
            [Jason.encode!(resp, pretty: true)]

          _ ->
            []
        end)
        |> Enum.join("\n")
        |> case do
          "" -> nil
          text -> text
        end

      is_map(call["result"]) ->
        Jason.encode!(call["result"], pretty: true)

      true ->
        nil
    end
  end

  # ── Pi event processing ──

  defp build_pi_stream_events(events) do
    flat =
      events
      |> Enum.reject(fn e ->
        e.type in ["session", "model_change", "thinking_level_change"]
      end)
      |> Enum.flat_map(&pi_event_to_stream/1)
      |> merge_pi_tool_results()

    grouped = group_into_collapsible(flat)
    {grouped, "", nil}
  end

  defp pi_event_to_stream(%{type: "message", data: data} = event) do
    role = get_in(data, ["message", "role"])
    content = get_in(data, ["message", "content"]) || []

    case role do
      "user" ->
        text =
          content
          |> Enum.flat_map(fn
            %{"type" => "text", "text" => t} when is_binary(t) -> [t]
            _ -> []
          end)
          |> Enum.join("\n")

        if String.trim(text) != "" do
          [%{type: "user.message", data: %{"content" => text}, dom_id: event.dom_id}]
        else
          []
        end

      "assistant" ->
        Enum.flat_map(content, fn
          %{"type" => "thinking", "thinking" => thinking}
          when is_binary(thinking) and thinking != "" ->
            [
              %{
                type: "assistant.reasoning",
                data: %{"content" => thinking},
                dom_id: "pi-thinking-#{System.unique_integer([:positive])}"
              }
            ]

          %{"type" => "text", "text" => text}
          when is_binary(text) and text != "" ->
            [
              %{
                type: "assistant.message.block",
                data: %{"content" => text},
                dom_id: "pi-text-#{System.unique_integer([:positive])}"
              }
            ]

          %{"type" => "toolCall", "name" => name, "id" => id} = call ->
            [
              %{
                type: "tool.combined",
                data: %{
                  "toolName" => name,
                  "toolCallId" => id,
                  "arguments" => call["arguments"] || %{},
                  "completed" => false
                },
                dom_id: "pi-tool-#{id}"
              }
            ]

          _ ->
            []
        end)

      "toolResult" ->
        tool_call_id = get_in(data, ["message", "toolCallId"])
        tool_name = get_in(data, ["message", "toolName"])
        is_error = get_in(data, ["message", "isError"]) == true

        result_text =
          content
          |> Enum.flat_map(fn
            %{"type" => "text", "text" => t} when is_binary(t) -> [t]
            _ -> []
          end)
          |> Enum.join("\n")

        [
          %{
            type: "tool.execution_complete",
            data: %{
              "toolCallId" => tool_call_id,
              "toolName" => tool_name,
              "result" => result_text,
              "success" => !is_error,
              "error" => if(is_error, do: result_text)
            },
            dom_id: "pi-tool-result-#{tool_call_id || System.unique_integer([:positive])}"
          }
        ]

      _ ->
        []
    end
  end

  defp pi_event_to_stream(_event), do: []

  defp merge_pi_tool_results(events) do
    outputs =
      events
      |> Enum.filter(&(&1.type == "tool.execution_complete"))
      |> Map.new(&{&1.data["toolCallId"], &1.data})

    Enum.flat_map(events, fn event ->
      case event.type do
        "tool.combined" ->
          case Map.get(outputs, event.data["toolCallId"]) do
            nil ->
              [event]

            output_data ->
              [
                %{
                  event
                  | data:
                      Map.merge(event.data, %{
                        "completed" => true,
                        "success" => output_data["success"],
                        "result" => output_data["result"],
                        "error" => output_data["error"]
                      })
                }
              ]
          end

        "tool.execution_complete" ->
          if Map.has_key?(outputs, event.data["toolCallId"]) &&
               Enum.any?(
                 events,
                 &(&1.type == "tool.combined" &&
                     &1.data["toolCallId"] == event.data["toolCallId"])
               ) do
            []
          else
            [event]
          end

        _ ->
          [event]
      end
    end)
  end

  @impl true
  def handle_event("send_prompt", %{"prompt" => prompt} = params, socket) do
    prompt = String.trim(prompt)

    if prompt == "" and socket.assigns.pasted_contents == [] do
      {:noreply, socket}
    else
      selected_model = params["model"] || socket.assigns.model
      resolved = socket.assigns.resolved_files

      # Append <pasted_content> tags for any pending paste attachments
      paste_tags =
        socket.assigns.pasted_contents
        |> Enum.reverse()
        |> Enum.map_join("\n\n", fn p ->
          "<pasted_content file=\"#{p.path}\" size=\"#{p.size}\" lines=\"#{p.lines}\" />"
        end)

      full_prompt =
        if paste_tags == "", do: prompt, else: prompt <> "\n\n" <> paste_tags

      # Extract inline @mentions in order of appearance and build attachments
      {attachments, file_maps} = extract_inline_attachments(full_prompt, resolved)

      # Inject user message into stream immediately (server echo is filtered out)
      user_data =
        if attachments == [] do
          %{"content" => full_prompt}
        else
          %{"content" => full_prompt, "attachments" => file_maps}
        end

      user_event = %{
        type: "user.message",
        data: user_data,
        dom_id: "user-msg-#{System.unique_integer([:positive])}"
      }

      send_opts =
        [model: selected_model] ++ if(attachments == [], do: [], else: [attachments: attachments])

      socket =
        socket
        |> assign(:prompt, "")
        |> assign(:model, selected_model)
        |> assign(:selected_files, [])
        |> assign(:resolved_files, %{})
        |> assign(:file_suggestions, [])
        |> assign(:file_query, "")
        |> assign(:pasted_contents, [])
        |> stream_insert(:events, user_event, at: -1)

      SessionServer.send_prompt(socket.assigns.session_id, full_prompt, send_opts)
      {:noreply, push_event(socket, "scroll-bottom", %{})}
    end
  end

  def handle_event("paste_content", %{"content" => content}, socket)
      when byte_size(content) > 0 do
    provider_id = CopilotLv.Sessions.Session.provider_id(socket.assigns.session_id)

    case resolve_session_files_dir(provider_id) do
      {:ok, files_dir} ->
        timestamp = System.os_time(:millisecond)
        filename = "paste-#{timestamp}.txt"
        file_path = Path.join(files_dir, filename)

        File.write!(file_path, content)

        lines = content |> String.split("\n") |> length()
        size = format_file_size(byte_size(content))

        paste_info = %{
          path: file_path,
          filename: filename,
          size: size,
          lines: lines
        }

        tag =
          "<pasted_content file=\"#{file_path}\" size=\"#{size}\" lines=\"#{lines}\" />"

        {:noreply,
         socket
         |> update(:pasted_contents, &[paste_info | &1])
         |> push_event("paste_stored", %{tag: tag, filename: filename, size: size, lines: lines})}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not save pasted content")}
    end
  end

  def handle_event("remove_paste", %{"index" => index}, socket) do
    index = String.to_integer(index)
    pasted = List.delete_at(socket.assigns.pasted_contents, index)
    {:noreply, assign(socket, :pasted_contents, pasted)}
  end

  def handle_event("update_prompt", %{"prompt" => prompt} = params, socket) do
    {suggestions, file_query} = detect_at_mention(prompt, socket)

    # Only reset picker index when the query (and thus the suggestions list) changes
    picker_index =
      if file_query == socket.assigns.file_query,
        do: socket.assigns.file_picker_index,
        else: 0

    # Preserve the selected model from the form so that re-renders
    # don't snap the <select> back to the previous value.
    selected_model = params["model"] || socket.assigns.model

    {:noreply,
     socket
     |> assign(:prompt, prompt)
     |> assign(:model, selected_model)
     |> assign(:file_suggestions, suggestions)
     |> assign(:file_query, file_query)
     |> assign(:file_picker_index, picker_index)}
  end

  def handle_event("select_file", %{"path" => path, "type" => type, "name" => name}, socket) do
    file = %{path: path, type: type, display_name: name}

    # Add to resolved files map (keyed by display_name for lookup on submit)
    resolved = Map.put(socket.assigns.resolved_files, name, file)

    # Replace @query with @display_name inline in the prompt text
    prompt = socket.assigns.prompt
    query = socket.assigns.file_query
    mention = "@#{name}"

    # Replace the last @query in the prompt with @display_name
    new_prompt = replace_last_at_query(prompt, query, mention)

    {:noreply,
     socket
     |> assign(
       resolved_files: resolved,
       file_suggestions: [],
       file_query: "",
       prompt: new_prompt,
       file_picker_index: -1
     )
     |> push_event("refocus-prompt", %{value: new_prompt, cursor: String.length(new_prompt)})}
  end

  def handle_event("remove_file", %{"path" => path}, socket) do
    # Remove from resolved_files by finding the entry with this path
    resolved =
      socket.assigns.resolved_files
      |> Enum.reject(fn {_name, f} -> f.path == path end)
      |> Map.new()

    {:noreply, assign(socket, resolved_files: resolved)}
  end

  def handle_event("file_picker_key", %{"key" => "ArrowDown"}, socket) do
    max = length(socket.assigns.file_suggestions) - 1
    idx = min(socket.assigns.file_picker_index + 1, max)

    {:noreply,
     socket
     |> assign(file_picker_index: idx)
     |> push_event("scroll-picker", %{index: idx})}
  end

  def handle_event("file_picker_key", %{"key" => "ArrowUp"}, socket) do
    idx = max(socket.assigns.file_picker_index - 1, -1)

    {:noreply,
     socket
     |> assign(file_picker_index: idx)
     |> push_event("scroll-picker", %{index: idx})}
  end

  def handle_event("file_picker_key", %{"key" => "Enter"}, socket) do
    idx = socket.assigns.file_picker_index

    if idx >= 0 and idx < length(socket.assigns.file_suggestions) do
      file = Enum.at(socket.assigns.file_suggestions, idx)

      handle_event(
        "select_file",
        %{"path" => file.path, "type" => file.type, "name" => file.display_name},
        socket
      )
    else
      {:noreply, socket}
    end
  end

  def handle_event("file_picker_key", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, file_suggestions: [], file_query: "", file_picker_index: -1)}
  end

  def handle_event("file_picker_key", %{"key" => "Tab"}, socket) do
    idx = socket.assigns.file_picker_index
    # If nothing highlighted, select first; otherwise select highlighted
    actual_idx = if idx < 0, do: 0, else: idx

    if actual_idx < length(socket.assigns.file_suggestions) do
      file = Enum.at(socket.assigns.file_suggestions, actual_idx)

      handle_event(
        "select_file",
        %{"path" => file.path, "type" => file.type, "name" => file.display_name},
        socket
      )
    else
      {:noreply, socket}
    end
  end

  def handle_event("file_picker_key", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("stop_session", _, socket) do
    SessionRegistry.stop_session(socket.assigns.session_id)
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_event("delete_session", _, socket) do
    id = socket.assigns.session_id

    case SessionRegistry.delete_session(id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Session deleted")
         |> push_navigate(to: ~p"/")}

      {:error, :starred} ->
        {:noreply, put_flash(socket, :error, "Unstar the session before deleting")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete session")}
    end
  end

  def handle_event("toggle_star", _, socket) do
    id = socket.assigns.session_id
    SessionRegistry.toggle_star(id)
    {:noreply, assign(socket, :starred, !socket.assigns.starred)}
  end

  def handle_event("resume_session", _, socket) do
    id = socket.assigns.session_id

    case SessionRegistry.resume_session(id) do
      {:ok, ^id} ->
        PubSub.subscribe(CopilotLv.PubSub, SessionServer.topic(id))

        socket =
          socket
          |> assign(:active, true)
          |> assign(:status, :idle)
          |> put_flash(:info, "Session resumed")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Resume failed: #{inspect(reason)}")}
    end
  end

  def handle_event("ask_user_select", %{"choice" => choice}, socket) do
    respond_to_ask_user(socket, choice)
  end

  def handle_event("ask_user_freeform_change", %{"response" => text}, socket) do
    {:noreply, assign(socket, :ask_user_freeform, text)}
  end

  def handle_event("ask_user_freeform_submit", %{"response" => text}, socket) do
    text = String.trim(text)

    if text == "" do
      {:noreply, socket}
    else
      respond_to_ask_user(socket, text)
    end
  end

  def handle_event("ask_user_dismiss", _, socket) do
    case socket.assigns.ask_user_request do
      %{request_id: request_id} ->
        CopilotLv.AskUserBroker.respond(
          request_id,
          "User dismissed the question without answering."
        )

      _ ->
        :ok
    end

    {:noreply, assign(socket, ask_user_request: nil, ask_user_freeform: "")}
  end

  def handle_event("toggle_inspector", _params, socket) do
    {:noreply, assign(socket, :inspector_open, !socket.assigns.inspector_open)}
  end

  def handle_event("select_inspector_tab", %{"tab" => tab}, socket) do
    tab =
      case tab do
        "artifacts" -> :artifacts
        _ -> :checkpoints
      end

    {:noreply, assign(socket, :inspector_tab, tab)}
  end

  def handle_event("select_checkpoint", %{"id" => checkpoint_id}, socket) do
    {:noreply,
     socket
     |> assign(:inspector_tab, :checkpoints)
     |> assign(:selected_checkpoint_id, checkpoint_id)}
  end

  def handle_event("select_artifact", %{"id" => artifact_id}, socket) do
    {:noreply,
     socket
     |> assign(:inspector_tab, :artifacts)
     |> assign(:selected_artifact_id, artifact_id)}
  end

  def handle_event("view_file", %{"token" => token, "line" => line}, socket) do
    alias CopilotLvWeb.FileViewer

    line = if is_binary(line), do: String.to_integer(line), else: line

    with {:ok, path} <- FileViewer.verify_token(CopilotLvWeb.Endpoint, token),
         allowed_bases <- [socket.assigns.cwd, socket.assigns.git_root] |> Enum.reject(&is_nil/1),
         true <- FileViewer.path_allowed?(path, allowed_bases),
         {:ok, content} <- FileViewer.read_file(path) do
      {:noreply,
       assign(socket, :file_viewer, %{
         path: path,
         filename: Path.basename(path),
         content: content,
         line: line,
         lang: FileViewer.detect_language(path)
       })}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Unable to view file")}
    end
  end

  def handle_event("view_file", %{"token" => token}, socket) do
    handle_event("view_file", %{"token" => token, "line" => 0}, socket)
  end

  def handle_event("view_content", %{"path" => path, "session-id" => session_id}, socket) do
    case SessionArtifact
         |> Ash.Query.for_read(:for_session, %{session_id: session_id})
         |> Ash.read!()
         |> Enum.find(&(&1.path == path)) do
      %{content: content} when is_binary(content) ->
        filename = Path.basename(path)

        {:noreply,
         assign(socket, :file_viewer, %{
           path: path,
           filename: filename,
           content: content,
           line: 0,
           lang: CopilotLvWeb.FileViewer.detect_language(filename)
         })}

      _ ->
        {:noreply, put_flash(socket, :error, "Content not found")}
    end
  end

  def handle_event("close_file_viewer", _params, socket) do
    {:noreply, assign(socket, :file_viewer, nil)}
  end

  def handle_event("set_view_mode", %{"mode" => mode}, socket) do
    view_mode = if mode == "terminal", do: :terminal, else: :rich

    socket =
      if view_mode == :terminal do
        terminal_events =
          socket.assigns.terminal_events
          |> Enum.map(&EventAdapter.convert_event/1)

        assign(socket, view_mode: :terminal, terminal_events: terminal_events)
      else
        assign(socket, view_mode: :rich)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:session_event, event}, socket) do
    type = map_get(event, :type)
    data = map_get(event, :data) || %{}

    cond do
      # Skip events we handle ourselves or are internal noise
      type in ["user.message"] or MapSet.member?(@noise_event_types, type) ->
        {:noreply, socket}

      # Accumulate assistant.message chunks into a single markdown block
      type == "assistant.message" ->
        chunk = data["chunkContent"] || data["content"] || ""
        new_text = socket.assigns.assistant_text <> chunk

        msg_id =
          socket.assigns.assistant_msg_id || "assistant-msg-#{System.unique_integer([:positive])}"

        event_map = %{
          type: "assistant.message.block",
          data: %{"content" => new_text},
          dom_id: msg_id
        }

        socket =
          socket
          |> assign(:assistant_text, new_text)
          |> assign(:assistant_msg_id, msg_id)
          |> stream_insert(:events, event_map, at: -1)
          |> push_file_tokens_for_text(chunk)

        {:noreply, push_event(socket, "scroll-bottom", %{})}

      # Tool start: add combined card to tool group
      type == "tool.execution_start" ->
        tool_call_id = data["toolCallId"]
        tool_name = data["toolName"] || "unknown"
        arguments = data["arguments"]

        combined = %{
          type: "tool.combined",
          data: %{
            "toolName" => tool_name,
            "arguments" => arguments,
            "toolCallId" => tool_call_id,
            "completed" => false
          },
          dom_id: "tool-#{tool_call_id || System.unique_integer([:positive])}"
        }

        pending =
          Map.put(socket.assigns.pending_tools, tool_call_id, %{
            tool_name: tool_name,
            arguments: arguments
          })

        socket =
          socket
          |> assign(:pending_tools, pending)
          |> add_to_tool_group(combined)

        {:noreply, push_event(socket, "scroll-bottom", %{})}

      # Tool complete: update the combined card in the tool group
      type == "tool.execution_complete" ->
        tool_call_id = data["toolCallId"]
        tool_info = Map.get(socket.assigns.pending_tools, tool_call_id)

        if tool_info do
          updates = %{
            "completed" => true,
            "success" => data["success"],
            "result" => data["result"],
            "error" => data["error"]
          }

          pending = Map.delete(socket.assigns.pending_tools, tool_call_id)

          socket =
            socket
            |> assign(:pending_tools, pending)
            |> update_in_tool_group(tool_call_id, updates)

          {:noreply, push_event(socket, "scroll-bottom", %{})}
        else
          insert_event(socket, event)
        end

      # Reset accumulator on turn boundaries, start fresh tool group
      type == "assistant.turn_start" ->
        socket =
          socket
          |> assign(:assistant_text, "")
          |> assign(:assistant_msg_id, nil)
          |> reset_tool_group()

        {:noreply, socket}

      # Intent, reasoning, usage, and other events go into the tool group
      true ->
        event_map = %{
          type: type,
          data: data,
          dom_id: "ev-#{System.unique_integer([:positive])}"
        }

        socket = add_to_tool_group(socket, event_map)
        {:noreply, push_event(socket, "scroll-bottom", %{})}
    end
  end

  def handle_info({:session_status, status}, socket) do
    {:noreply, assign(socket, :status, status)}
  end

  def handle_info({:session_model_changed, model}, socket) do
    {:noreply, assign(socket, :model, model)}
  end

  def handle_info({:session_error, message}, socket) do
    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_info({:ask_user_request, request}, socket) do
    {:noreply, assign(socket, :ask_user_request, request)}
  end

  def handle_info(:ask_user_timeout, socket) do
    {:noreply, assign(socket, ask_user_request: nil, ask_user_freeform: "")}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp insert_event(socket, event) do
    dom_id = "ev-#{map_get(event, :id) || System.unique_integer([:positive])}"

    event_map =
      case event do
        %{__struct__: _} -> Map.from_struct(event)
        map when is_map(map) -> map
      end
      |> Map.put(:dom_id, dom_id)

    socket =
      socket
      |> track_terminal_event(event_map)
      |> stream_insert(:events, event_map, at: -1)

    {:noreply, push_event(socket, "scroll-bottom", %{})}
  end

  defp track_terminal_event(socket, event_map) do
    terminal_events = socket.assigns.terminal_events ++ [event_map]
    socket = assign(socket, :terminal_events, terminal_events)

    if socket.assigns.view_mode == :terminal do
      session_event = EventAdapter.convert_event(event_map)
      ansi = Terminal.format_event(session_event)
      push_event(socket, "xterm:write", %{data: ansi, target: "session-terminal"})
    else
      socket
    end
  end

  # ── Live Tool Group Helpers ──

  defp add_to_tool_group(socket, event_data) do
    group_events = socket.assigns.tool_group_events ++ [event_data]

    group_id =
      socket.assigns.tool_group_id || "tool-group-live-#{System.unique_integer([:positive])}"

    group = build_tool_group(group_events, group_id)

    socket
    |> assign(:tool_group_events, group_events)
    |> assign(:tool_group_id, group_id)
    |> stream_insert(:events, group, at: -1)
  end

  defp update_in_tool_group(socket, tool_call_id, updates) do
    group_events =
      Enum.map(socket.assigns.tool_group_events, fn evt ->
        if evt.type == "tool.combined" && evt.data["toolCallId"] == tool_call_id do
          %{evt | data: Map.merge(evt.data, updates)}
        else
          evt
        end
      end)

    group = build_tool_group(group_events, socket.assigns.tool_group_id)

    socket
    |> assign(:tool_group_events, group_events)
    |> stream_insert(:events, group, at: -1)
  end

  defp reset_tool_group(socket) do
    socket
    |> assign(:tool_group_events, [])
    |> assign(:tool_group_id, nil)
  end

  defp build_tool_group(events, group_id) do
    tool_events = Enum.filter(events, &(&1.type == "tool.combined"))
    tool_names = tool_events |> Enum.map(& &1.data["toolName"]) |> Enum.uniq()

    %{
      type: "tool.group",
      data: %{
        "events" => events,
        "tool_names" => tool_names,
        "tool_count" => length(tool_events)
      },
      dom_id: group_id
    }
  end

  defp respond_to_ask_user(socket, response) do
    case socket.assigns.ask_user_request do
      %{request_id: request_id} ->
        CopilotLv.AskUserBroker.respond(request_id, response)
        {:noreply, assign(socket, ask_user_request: nil, ask_user_freeform: "")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-base-200" id="session-container" phx-hook="AutoScroll">
      <%!-- Header --%>
      <header class="navbar bg-base-100 shadow-sm px-4 flex-shrink-0">
        <div class="flex-1 gap-3">
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">← Sessions</.link>
          <div class="text-sm font-mono text-base-content/70">{@cwd}</div>
          <div class={"badge #{status_badge(@status)}"}>{@status}</div>
          <%= if @model do %>
            <div class="badge badge-outline">{@model}</div>
          <% end %>
        </div>
        <div class="flex-none gap-2">
          <div class="join mr-2">
            <button
              phx-click="set_view_mode"
              phx-value-mode="rich"
              class={[
                "join-item btn btn-xs",
                if(@view_mode == :rich, do: "btn-primary", else: "btn-ghost")
              ]}
            >
              Rich
            </button>
            <button
              phx-click="set_view_mode"
              phx-value-mode="terminal"
              class={[
                "join-item btn btn-xs",
                if(@view_mode == :terminal, do: "btn-primary", else: "btn-ghost")
              ]}
            >
              Terminal
            </button>
          </div>
          <button
            phx-click="toggle_star"
            class={[
              "btn btn-sm btn-ghost text-lg",
              if(@starred, do: "text-amber-400", else: "text-base-content/30")
            ]}
            title={if @starred, do: "Unstar", else: "Star"}
          >
            <%= if @starred do %>
              ★
            <% else %>
              ☆
            <% end %>
          </button>
          <%= if @active do %>
            <button phx-click="stop_session" class="btn btn-sm btn-error btn-outline">
              Stop
            </button>
          <% else %>
            <button phx-click="resume_session" class="btn btn-sm btn-success btn-outline">
              ▶ Resume
            </button>
            <%= unless @starred do %>
              <button
                phx-click="delete_session"
                data-confirm="Delete this session? This removes it from the database and disk permanently."
                class="btn btn-sm btn-error btn-outline"
              >
                Delete
              </button>
            <% end %>
            <.link navigate={~p"/"} class="btn btn-sm btn-ghost">← Back</.link>
          <% end %>
        </div>
      </header>

      <%!-- Resume command --%>
      <%= if @session_id do %>
        <div class="border-b border-base-300 bg-base-300/50 px-4 py-2 flex flex-col gap-2 flex-shrink-0">
          <div class="flex items-center gap-2">
            <code
              id="resume-command"
              class="flex-1 text-xs font-mono text-base-content/80 bg-base-100 rounded px-3 py-1.5 select-all overflow-x-auto whitespace-nowrap"
            >
              {resume_command(@agent, @hostname, @cwd, @session_id)}
            </code>
            <button
              id="copy-resume-cmd"
              type="button"
              phx-hook=".CopyTextButton"
              data-copy-text={resume_command(@agent, @hostname, @cwd, @session_id)}
              data-success-label="✓"
              class="btn btn-ghost btn-xs tooltip tooltip-left"
              aria-label="Copy to clipboard"
              data-tip="Copy"
            >
              📋
            </button>
          </div>

          <div class="flex flex-col gap-2 rounded-lg border border-base-300 bg-base-100/70 px-3 py-2 md:flex-row md:items-center">
            <div class="min-w-0 flex-1">
              <div class="text-[0.65rem] font-semibold uppercase tracking-[0.2em] text-base-content/50">
                Agent handoff
              </div>
              <code
                id="handoff-command"
                class="mt-1 block overflow-x-auto whitespace-nowrap rounded bg-base-100 px-2 py-1 text-xs font-mono text-base-content/80"
              >
                curl --silent {handoff_url(@session_id)}
              </code>
            </div>

            <button
              id="copy-handoff-prompt"
              type="button"
              phx-hook=".CopyTextButton"
              data-copy-text={handoff_prompt(@session_id)}
              data-handoff-url={handoff_url(@session_id)}
              data-success-label="Copied!"
              class="btn btn-sm btn-primary btn-outline md:self-start"
            >
              Copy handoff prompt
            </button>
          </div>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyTextButton">
            export default {
              mounted() {
                this.originalLabel = this.el.textContent

                this.el.addEventListener("click", async (event) => {
                  event.preventDefault()
                  event.stopPropagation()

                  const text = this.el.getAttribute("data-copy-text") || ""
                  const original = this.originalLabel || this.el.textContent
                  const successLabel = this.el.getAttribute("data-success-label") || "Copied!"

                  const copied = await this.copyText(text)
                  this.el.textContent = copied ? successLabel : "Failed"
                  setTimeout(() => { this.el.textContent = original }, 1500)
                })
              },

              async copyText(text) {
                if (navigator.clipboard?.writeText) {
                  try {
                    await navigator.clipboard.writeText(text)
                    return true
                  } catch (_error) {
                    // Fall back to execCommand below for browsers or contexts that reject the async API.
                  }
                }

                return this.fallbackCopy(text)
              },

              fallbackCopy(text) {
                const helper = document.createElement("textarea")
                helper.value = text
                helper.setAttribute("readonly", "")
                helper.style.position = "fixed"
                helper.style.left = "-9999px"
                helper.style.top = "-9999px"
                helper.style.opacity = "0"

                document.body.appendChild(helper)
                helper.focus()
                helper.select()
                helper.setSelectionRange(0, helper.value.length)

                try {
                  return document.execCommand("copy")
                } catch (_error) {
                  return false
                } finally {
                  document.body.removeChild(helper)
                }
              }
            }
          </script>
        </div>
      <% end %>

      <%!-- Event stream + inspector --%>
      <div class="flex-1 min-h-0 flex flex-col xl:flex-row">
        <main class="flex-1 min-h-0 overflow-y-auto p-4 space-y-2" id="event-scroll">
          <%= if @view_mode == :rich do %>
            <div id="events" phx-update="stream">
              <div :for={{dom_id, event} <- @streams.events} id={dom_id}>
                <.event_item event={event} session_id={@session_id} />
              </div>
            </div>
          <% else %>
            <Terminal.terminal_view
              id="session-terminal"
              events={@terminal_events}
              class="h-full"
            />
          <% end %>
        </main>

        <aside class={[
          "border-base-300 bg-base-100/80 transition-all duration-200 ease-in-out",
          if(@inspector_open,
            do:
              "h-[28rem] border-t xl:h-auto xl:w-[30rem] xl:flex-shrink-0 xl:border-l xl:border-t-0",
            else: "h-auto border-t xl:h-auto xl:w-auto xl:border-l xl:border-t-0"
          )
        ]}>
          <%= if @inspector_open do %>
            <.session_inspector
              inspector_tab={@inspector_tab}
              checkpoints={@checkpoints}
              selected_checkpoint_id={@selected_checkpoint_id}
              artifacts={@artifacts}
              selected_artifact_id={@selected_artifact_id}
            />
          <% else %>
            <button
              id="inspector-expand-btn"
              phx-click="toggle_inspector"
              class="flex w-full items-center justify-center gap-2 px-4 py-2 text-xs font-semibold uppercase tracking-widest text-base-content/50 hover:text-base-content/80 hover:bg-base-200/60 transition-colors xl:h-full xl:w-10 xl:flex-col xl:py-4 xl:px-1"
              title="Open inspector"
            >
              <.icon name="hero-magnifying-glass" class="h-3.5 w-3.5" />
              <span class="xl:hidden">Inspector</span>
              <span class="hidden xl:[writing-mode:vertical-lr] xl:block">Inspector</span>
            </button>
          <% end %>
        </aside>
      </div>

      <%!-- ask_user modal --%>
      <%= if @ask_user_request do %>
        <.ask_user_modal
          request={@ask_user_request}
          freeform_text={@ask_user_freeform}
        />
      <% end %>

      <%!-- File viewer modal --%>
      <%= if @file_viewer do %>
        <.file_viewer_modal file={@file_viewer} />
      <% end %>

      <%!-- Usage bar --%>
      <%= if @usage != [] do %>
        <.usage_bar usage={@usage} />
      <% end %>

      <%!-- Prompt input with model selector and @ file picker (only for active sessions) --%>
      <%= if @active do %>
        <footer class="bg-base-100 border-t border-base-300 p-4 flex-shrink-0">
          <form phx-submit="send_prompt" phx-change="update_prompt" class="flex gap-2 items-center">
            <select
              name="model"
              class="select select-bordered select-sm w-auto max-w-48"
              disabled={@status != :idle}
            >
              <%= for {name, id, multiplier} <- @models do %>
                <option value={id} selected={id == @model}>
                  {name} ({format_multiplier(multiplier)})
                </option>
              <% end %>
            </select>
            <div class="relative flex-1">
              <textarea
                name="prompt"
                id="prompt-input"
                phx-debounce="100"
                placeholder={
                  if @status == :idle, do: "Type a message... (@ to attach files)", else: "Waiting..."
                }
                disabled={@status != :idle}
                class="textarea textarea-bordered w-full resize-none overflow-hidden min-h-[2.5rem] py-2 leading-normal"
                rows="1"
                autocomplete="off"
                autofocus
                phx-hook=".FilePickerKeys"
                data-picker-active={if(@file_suggestions != [], do: "true", else: "false")}
              >{@prompt}</textarea>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".FilePickerKeys">
                const PASTE_SIZE_THRESHOLD = 1024  // 1 KB

                export default {
                  mounted() {
                    this.autoResize = () => {
                      this.el.style.height = "auto"
                      this.el.style.height = this.el.scrollHeight + "px"
                    }

                    this.el.addEventListener("input", () => this.autoResize())

                    // Detect large pastes and offload to server as files
                    this.el.addEventListener("paste", (e) => {
                      const text = e.clipboardData?.getData("text/plain")
                      if (text && text.length > PASTE_SIZE_THRESHOLD) {
                        e.preventDefault()
                        this.pushEvent("paste_content", { content: text })
                      }
                    })

                    this.el.addEventListener("keydown", (e) => {
                      if (e.key === "Enter" && !e.shiftKey) {
                        if (this.el.dataset.pickerActive === "true") {
                          e.preventDefault()
                          this.pushEvent("file_picker_key", {key: e.key})
                          return
                        }
                        e.preventDefault()
                        this.el.closest("form").dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}))
                        return
                      }

                      if (this.el.dataset.pickerActive !== "true") return
                      if (["ArrowUp", "ArrowDown", "Escape", "Tab"].includes(e.key)) {
                        e.preventDefault()
                        this.pushEvent("file_picker_key", {key: e.key})
                      }
                    })

                    this.handleEvent("refocus-prompt", ({value, cursor}) => {
                      requestAnimationFrame(() => {
                        this.el.blur()
                        if (value != null) {
                          this.el.value = value
                        }
                        this.el.focus()
                        if (typeof cursor === "number") {
                          this.el.setSelectionRange(cursor, cursor)
                        }
                        this.autoResize()
                      })
                    })

                    this.handleEvent("scroll-picker", ({index}) => {
                      requestAnimationFrame(() => {
                        const picker = document.getElementById("file-tree-picker")
                        if (!picker) return
                        if (index < 0) {
                          picker.scrollTop = 0
                          return
                        }
                        const item = picker.querySelector(`[data-picker-index="${index}"]`)
                        if (item) {
                          item.scrollIntoView({block: "nearest"})
                        }
                      })
                    })
                  },
                  updated() {
                    this.autoResize()
                  }
                }
              </script>
              <%!-- File suggestion tree dropdown --%>
              <%= if @file_suggestions != [] do %>
                <.file_tree_picker
                  suggestions={@file_suggestions}
                  query={@file_query}
                  picker_index={@file_picker_index}
                />
              <% end %>
            </div>
            <button type="submit" class="btn btn-primary" disabled={@status != :idle}>
              Send
            </button>
          </form>
          <%= if @pasted_contents != [] do %>
            <div class="flex flex-wrap gap-1.5 mt-2 px-1">
              <%= for {paste, idx} <- Enum.with_index(@pasted_contents) do %>
                <div class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-base-200 border border-base-300 text-xs font-medium">
                  <span class="opacity-60">📎</span>
                  <span class="truncate max-w-48">{paste.filename}</span>
                  <span class="opacity-50">{paste.size} · {paste.lines} lines</span>
                  <button
                    type="button"
                    phx-click="remove_paste"
                    phx-value-index={idx}
                    class="ml-0.5 opacity-40 hover:opacity-100 transition-opacity"
                  >
                    <.icon name="hero-x-mark" class="h-3 w-3" />
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>
        </footer>
      <% end %>
    </div>
    """
  end

  # ── Event Components ──
  # Delegates to the shared Rich component via the adapter

  defp event_item(assigns) do
    event = enrich_user_message_with_pasted_content(assigns.event)
    session_event = EventAdapter.convert_event(event)

    session_event = %{
      session_event
      | metadata: Map.put(session_event.metadata, :session_id, assigns.session_id)
    }

    assigns = assign(assigns, :event, session_event)
    Rich.event_item(assigns)
  end

  defp session_inspector(assigns) do
    assigns =
      assigns
      |> assign(:checkpoint_count, length(assigns.checkpoints))
      |> assign(:artifact_count, length(assigns.artifacts))
      |> assign(
        :selected_checkpoint,
        select_item(assigns.checkpoints, assigns.selected_checkpoint_id)
      )
      |> assign(:selected_artifact, select_item(assigns.artifacts, assigns.selected_artifact_id))

    ~H"""
    <div id="session-inspector" class="flex h-full min-h-0 flex-col">
      <div class="border-b border-base-300 px-4 py-4">
        <div class="flex items-start justify-between gap-3">
          <div>
            <p class="text-[0.7rem] font-semibold uppercase tracking-[0.24em] text-base-content/45">
              Session inspector
            </p>
            <h2 class="mt-1 text-sm font-semibold text-base-content">
              Checkpoints and imported artifacts
            </h2>
          </div>
          <div class="flex items-center gap-2">
            <div class="badge badge-outline badge-sm">
              {@checkpoint_count + @artifact_count} items
            </div>
            <button
              id="inspector-close-btn"
              phx-click="toggle_inspector"
              class="btn btn-ghost btn-xs btn-circle text-base-content/50 hover:text-base-content"
              title="Close inspector"
            >
              <.icon name="hero-x-mark" class="h-4 w-4" />
            </button>
          </div>
        </div>

        <div class="mt-3 flex gap-2">
          <button
            id="checkpoint-tab"
            phx-click="select_inspector_tab"
            phx-value-tab="checkpoints"
            class={[
              "btn btn-sm flex-1 justify-between rounded-xl transition-all duration-150",
              if(@inspector_tab == :checkpoints,
                do: "btn-primary shadow-sm",
                else: "btn-ghost border border-base-300"
              )
            ]}
          >
            <span>Checkpoints</span>
            <span class="badge badge-sm border-0 bg-base-100/20">{@checkpoint_count}</span>
          </button>
          <button
            id="artifact-tab"
            phx-click="select_inspector_tab"
            phx-value-tab="artifacts"
            class={[
              "btn btn-sm flex-1 justify-between rounded-xl transition-all duration-150",
              if(@inspector_tab == :artifacts,
                do: "btn-primary shadow-sm",
                else: "btn-ghost border border-base-300"
              )
            ]}
          >
            <span>Artifacts</span>
            <span class="badge badge-sm border-0 bg-base-100/20">{@artifact_count}</span>
          </button>
        </div>
      </div>

      <div class="flex min-h-0 flex-1 flex-col gap-3 p-3">
        <div class="min-h-[12rem] overflow-y-auto rounded-2xl border border-base-300 bg-base-100/70 p-2">
          <%= if @inspector_tab == :checkpoints do %>
            <%= if @checkpoints == [] do %>
              <div
                id="checkpoint-empty-state"
                class="flex h-full min-h-[10rem] items-center justify-center rounded-xl border border-dashed border-base-300 bg-base-200/40 px-6 text-center text-sm text-base-content/55"
              >
                No checkpoints were imported for this session yet.
              </div>
            <% else %>
              <div id="checkpoint-list" class="space-y-2">
                <%= for checkpoint <- @checkpoints do %>
                  <button
                    id={"checkpoint-#{checkpoint.id}"}
                    phx-click="select_checkpoint"
                    phx-value-id={checkpoint.id}
                    class={[
                      "w-full rounded-2xl border px-3 py-3 text-left transition-all duration-150",
                      if(@selected_checkpoint_id == checkpoint.id,
                        do: "border-primary bg-primary/10 shadow-sm",
                        else:
                          "border-base-300 bg-base-100 hover:border-primary/40 hover:bg-base-200/70"
                      )
                    ]}
                  >
                    <div class="flex items-start justify-between gap-3">
                      <div class="min-w-0">
                        <div class="text-[0.7rem] font-semibold uppercase tracking-[0.22em] text-base-content/45">
                          Checkpoint {checkpoint.number}
                        </div>
                        <div class="mt-1 truncate text-sm font-semibold text-base-content">
                          {checkpoint.title || checkpoint.filename}
                        </div>
                      </div>
                      <span class={[
                        "badge badge-xs whitespace-nowrap",
                        if(checkpoint.compaction_success,
                          do: "badge-success",
                          else: "badge-ghost"
                        )
                      ]}>
                        {if checkpoint.compaction_success, do: "compacted", else: "saved"}
                      </span>
                    </div>

                    <div class="mt-2 text-xs leading-relaxed text-base-content/65">
                      {preview_text(checkpoint.content, 180)}
                    </div>

                    <div class="mt-3 flex flex-wrap gap-1.5">
                      <span class="badge badge-outline badge-xs">{checkpoint.filename}</span>
                      <%= if checkpoint.compaction_tokens do %>
                        <span class="badge badge-ghost badge-xs">
                          {format_tokens(checkpoint.compaction_tokens.input)} in
                        </span>
                        <span class="badge badge-ghost badge-xs">
                          {format_tokens(checkpoint.compaction_tokens.output)} out
                        </span>
                      <% end %>
                    </div>
                  </button>
                <% end %>
              </div>
            <% end %>
          <% else %>
            <%= if @artifacts == [] do %>
              <div
                id="artifact-empty-state"
                class="flex h-full min-h-[10rem] items-center justify-center rounded-xl border border-dashed border-base-300 bg-base-200/40 px-6 text-center text-sm text-base-content/55"
              >
                No imported artifacts were stored for this session.
              </div>
            <% else %>
              <div id="artifact-list" class="space-y-2">
                <%= for artifact <- @artifacts do %>
                  <button
                    id={"artifact-#{artifact.id}"}
                    phx-click="select_artifact"
                    phx-value-id={artifact.id}
                    class={[
                      "w-full rounded-2xl border px-3 py-3 text-left transition-all duration-150",
                      if(@selected_artifact_id == artifact.id,
                        do: "border-primary bg-primary/10 shadow-sm",
                        else:
                          "border-base-300 bg-base-100 hover:border-primary/40 hover:bg-base-200/70"
                      )
                    ]}
                  >
                    <div class="flex items-start justify-between gap-3">
                      <div class="min-w-0">
                        <div class="truncate font-mono text-[0.78rem] text-base-content/70">
                          {artifact.path}
                        </div>
                        <div class="mt-1 text-sm font-semibold text-base-content">
                          {artifact_type_label(artifact.artifact_type)}
                        </div>
                      </div>
                      <span class="badge badge-outline badge-xs whitespace-nowrap">
                        {format_bytes(artifact.size || 0)}
                      </span>
                    </div>

                    <div class="mt-2 text-xs leading-relaxed text-base-content/65">
                      {preview_text(artifact.content, 180)}
                    </div>
                  </button>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

        <div class="min-h-0 flex-1 overflow-y-auto rounded-2xl border border-base-300 bg-base-100/90">
          <%= if @inspector_tab == :checkpoints do %>
            <.checkpoint_detail checkpoint={@selected_checkpoint} />
          <% else %>
            <.artifact_detail artifact={@selected_artifact} />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp checkpoint_detail(assigns) do
    ~H"""
    <%= if @checkpoint do %>
      <div id="checkpoint-detail" class="flex h-full min-h-0 flex-col">
        <div class="border-b border-base-300 px-4 py-4">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-[0.7rem] font-semibold uppercase tracking-[0.22em] text-base-content/45">
                Checkpoint {@checkpoint.number}
              </p>
              <h3 class="mt-1 text-base font-semibold text-base-content">
                {@checkpoint.title || @checkpoint.filename}
              </h3>
              <p class="mt-1 font-mono text-xs text-base-content/55">{@checkpoint.filename}</p>
            </div>
            <div class="flex flex-wrap gap-1.5">
              <span class="badge badge-outline badge-sm">
                {format_bytes(byte_size(@checkpoint.content || ""))}
              </span>
              <%= if @checkpoint.compaction_timestamp do %>
                <span class="badge badge-ghost badge-sm">
                  {format_datetime(@checkpoint.compaction_timestamp)}
                </span>
              <% end %>
            </div>
          </div>
        </div>

        <div class="flex-1 space-y-4 overflow-y-auto px-4 py-4">
          <%= if @checkpoint.compaction_event do %>
            <div class="rounded-2xl border border-base-300 bg-base-200/60 p-4">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <h4 class="text-sm font-semibold text-base-content">Compaction metadata</h4>
                  <p class="mt-1 text-xs text-base-content/60">
                    Imported from
                    <code class="font-mono">{@checkpoint.compaction_path || "events.jsonl"}</code>
                  </p>
                </div>
                <span class={[
                  "badge badge-sm",
                  if(@checkpoint.compaction_success, do: "badge-success", else: "badge-error")
                ]}>
                  {if @checkpoint.compaction_success, do: "Success", else: "Failed"}
                </span>
              </div>

              <div class="mt-4 grid grid-cols-2 gap-2">
                <.inspector_metric
                  label="Input tokens"
                  value={format_tokens(@checkpoint.compaction_input_tokens || 0)}
                />
                <.inspector_metric
                  label="Output tokens"
                  value={format_tokens(@checkpoint.compaction_output_tokens || 0)}
                />
                <.inspector_metric
                  label="Cached input"
                  value={format_tokens(@checkpoint.compaction_cached_input_tokens || 0)}
                />
                <.inspector_metric
                  label="Messages compacted"
                  value={@checkpoint.pre_compaction_messages_length || 0}
                />
                <.inspector_metric
                  label="Pre-compaction tokens"
                  value={format_tokens(@checkpoint.pre_compaction_tokens || 0)}
                />
                <.inspector_metric
                  label="Request ID"
                  value={@checkpoint.request_id || "n/a"}
                  mono={true}
                />
              </div>
            </div>
          <% end %>

          <div class="space-y-2">
            <div class="flex items-center justify-between gap-3">
              <h4 class="text-sm font-semibold text-base-content">Checkpoint content</h4>
              <span class="text-xs text-base-content/45">
                {preview_text(@checkpoint.content, 48)}
              </span>
            </div>
            <pre
              id="checkpoint-content"
              class="overflow-x-auto rounded-2xl border border-base-300 bg-base-200/60 p-4 text-xs leading-relaxed text-base-content whitespace-pre-wrap"
            ><%= @checkpoint.content %></pre>
          </div>
        </div>
      </div>
    <% else %>
      <div
        id="checkpoint-detail-empty"
        class="flex h-full min-h-[12rem] items-center justify-center px-6 text-center text-sm text-base-content/55"
      >
        Select a checkpoint to inspect its compacted context and metadata.
      </div>
    <% end %>
    """
  end

  defp artifact_detail(assigns) do
    ~H"""
    <%= if @artifact do %>
      <div id="artifact-detail" class="flex h-full min-h-0 flex-col">
        <div class="border-b border-base-300 px-4 py-4">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-[0.7rem] font-semibold uppercase tracking-[0.22em] text-base-content/45">
                {artifact_type_label(@artifact.artifact_type)}
              </p>
              <h3 class="mt-1 truncate font-mono text-sm font-semibold text-base-content">
                {@artifact.path}
              </h3>
              <p class="mt-1 text-xs text-base-content/55">
                {preview_text(@artifact.content_hash, 18)}
              </p>
            </div>
            <div class="flex flex-wrap gap-1.5">
              <span class="badge badge-outline badge-sm">
                {artifact_type_label(@artifact.artifact_type)}
              </span>
              <span class="badge badge-ghost badge-sm">{format_bytes(@artifact.size || 0)}</span>
            </div>
          </div>
        </div>

        <div class="flex-1 space-y-2 overflow-y-auto px-4 py-4">
          <h4 class="text-sm font-semibold text-base-content">Stored content</h4>
          <pre
            id="artifact-content"
            class="overflow-x-auto rounded-2xl border border-base-300 bg-base-200/60 p-4 text-xs leading-relaxed text-base-content whitespace-pre-wrap"
          ><%= @artifact.content %></pre>
        </div>
      </div>
    <% else %>
      <div
        id="artifact-detail-empty"
        class="flex h-full min-h-[12rem] items-center justify-center px-6 text-center text-sm text-base-content/55"
      >
        Select an artifact to inspect the stored file contents.
      </div>
    <% end %>
    """
  end

  defp inspector_metric(assigns) do
    assigns = assign_new(assigns, :mono, fn -> false end)

    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100/80 px-3 py-2">
      <div class="text-[0.68rem] font-semibold uppercase tracking-[0.18em] text-base-content/45">
        {@label}
      </div>
      <div class={["mt-1 text-sm font-semibold text-base-content", if(@mono, do: "font-mono text-xs")]}>
        {@value}
      </div>
    </div>
    """
  end

  # ── File Viewer Modal ──

  defp file_viewer_modal(assigns) do
    lines = String.split(assigns.file.content, "\n")
    line_count = length(lines)
    target_line = assigns.file.line || 0

    assigns =
      assigns
      |> assign(:lines, lines)
      |> assign(:line_count, line_count)
      |> assign(:target_line, target_line)

    ~H"""
    <div
      id="file-viewer-overlay"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm"
      phx-window-keydown="close_file_viewer"
      phx-key="Escape"
    >
      <div
        id="file-viewer-dialog"
        class="relative mx-4 flex max-h-[85vh] w-full max-w-5xl flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl"
        phx-click-away="close_file_viewer"
      >
        <%!-- Header --%>
        <div class="flex items-center justify-between border-b border-base-300 px-5 py-3">
          <div class="flex items-center gap-3 min-w-0">
            <.icon name="hero-document-text" class="h-5 w-5 text-primary flex-shrink-0" />
            <div class="min-w-0">
              <h3 class="truncate text-sm font-semibold text-base-content" title={@file.path}>
                {@file.filename}
              </h3>
              <p class="truncate text-xs text-base-content/50" title={@file.path}>
                {@file.path}
                <%= if @target_line > 0 do %>
                  <span class="text-primary font-medium">:{@target_line}</span>
                <% end %>
              </p>
            </div>
          </div>
          <div class="flex items-center gap-2 flex-shrink-0">
            <span class="badge badge-ghost badge-sm">{@file.lang}</span>
            <span class="badge badge-outline badge-sm">{@line_count} lines</span>
            <button
              id="file-viewer-close-btn"
              phx-click="close_file_viewer"
              class="btn btn-ghost btn-sm btn-circle"
            >
              <.icon name="hero-x-mark" class="h-4 w-4" />
            </button>
          </div>
        </div>

        <%!-- File content with line numbers and syntax highlighting --%>
        <div
          id="file-viewer-content"
          class="flex-1 overflow-auto bg-base-200/50"
          phx-hook=".FileViewerHighlight"
          data-target-line={@target_line}
          data-lang={@file.lang}
          data-code={@file.content}
          phx-update="ignore"
        >
          <table class="w-full border-collapse font-mono text-xs leading-relaxed">
            <tbody>
              <%= for {line_text, idx} <- Enum.with_index(@lines, 1) do %>
                <tr
                  id={"file-line-#{idx}"}
                  class={[
                    "hover:bg-base-300/40",
                    if(idx == @target_line, do: "bg-warning/15 ring-1 ring-inset ring-warning/30")
                  ]}
                >
                  <td class={[
                    "select-none border-r border-base-300 px-3 py-0 text-right align-top text-base-content/35",
                    if(idx == @target_line, do: "text-warning font-semibold")
                  ]}>
                    {idx}
                  </td>
                  <td class="px-4 py-0 whitespace-pre break-all text-base-content file-viewer-line">
                    {line_text}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".FileViewerHighlight">
      import hljs from "highlight.js/lib/core"

      export default {
        mounted() {
          this.highlight()
          this.scrollToTarget()
        },

        highlight() {
          const lang = this.el.dataset.lang
          const code = this.el.dataset.code
          if (!code || lang === "plaintext") return

          try {
            let result
            if (lang && hljs.getLanguage(lang)) {
              result = hljs.highlight(code, { language: lang })
            } else {
              result = hljs.highlightAuto(code)
            }

            const highlightedLines = result.value.split("\n")
            const cells = this.el.querySelectorAll("td.file-viewer-line")

            cells.forEach((cell, i) => {
              if (i < highlightedLines.length) {
                cell.innerHTML = highlightedLines[i] || "\n"
              }
            })
          } catch (e) {
            // Highlighting failed — fall back to plain text (already rendered)
          }
        },

        scrollToTarget() {
          const line = this.el.dataset.targetLine
          if (line && parseInt(line) > 0) {
            const row = document.getElementById(`file-line-${line}`)
            if (row) {
              requestAnimationFrame(() => {
                row.scrollIntoView({ block: "center", behavior: "smooth" })
              })
            }
          }
        }
      }
    </script>
    """
  end

  # ── Usage Bar ──

  defp usage_bar(assigns) do
    total_in = Enum.sum(Enum.map(assigns.usage, & &1.input_tokens))
    total_out = Enum.sum(Enum.map(assigns.usage, & &1.output_tokens))

    # Only user-initiated calls count as premium requests (same as Copilot CLI)
    premium_cost =
      assigns.usage
      |> Enum.filter(&(&1.initiator == "user" && &1.cost != nil))
      |> Enum.map(& &1.cost)
      |> Enum.sum()

    calls = length(assigns.usage)

    # Per-model breakdown
    by_model =
      assigns.usage
      |> Enum.group_by(& &1.model)
      |> Enum.map(fn {model, entries} ->
        %{
          model: model || "unknown",
          input_tokens: Enum.sum(Enum.map(entries, & &1.input_tokens)),
          output_tokens: Enum.sum(Enum.map(entries, & &1.output_tokens)),
          cached: Enum.sum(Enum.map(entries, & &1.cache_read_tokens)),
          cost:
            entries
            |> Enum.filter(&(&1.initiator == "user" && &1.cost != nil))
            |> Enum.map(& &1.cost)
            |> Enum.sum(),
          count: length(entries)
        }
      end)
      |> Enum.sort_by(& &1.input_tokens, :desc)

    assigns =
      assign(assigns,
        total_in: total_in,
        total_out: total_out,
        premium_cost: premium_cost,
        calls: calls,
        by_model: by_model
      )

    ~H"""
    <div class="bg-base-100 border-t border-base-300 px-4 py-1 text-xs text-base-content/60">
      <div class="flex gap-4 items-center">
        <span>📊 {format_tokens(@total_in)} in → {format_tokens(@total_out)} out</span>
        <span>{@calls} API call{if @calls != 1, do: "s"}</span>
        <span>~{round(@premium_cost)} Premium request{if round(@premium_cost) != 1, do: "s"}</span>
      </div>
      <%= if length(@by_model) > 1 do %>
        <div class="flex gap-3 mt-0.5">
          <%= for m <- @by_model do %>
            <span class="font-mono">
              {m.model}: {format_tokens(m.input_tokens)} in, {format_tokens(m.output_tokens)} out<%= if m.cached > 0 do %>
                , {format_tokens(m.cached)} cached
              <% end %>
              (~{round(m.cost)} PR)
            </span>
          <% end %>
        </div>
      <% else %>
        <%= for m <- @by_model do %>
          <div class="mt-0.5 font-mono">
            {m.model} ({m.count} calls, {Jido.GHCopilot.Models.multiplier(m.model)}x multiplier)
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ── ask_user Modal ──

  defp ask_user_modal(assigns) do
    choices = assigns.request.choices || []
    allow_freeform = Map.get(assigns.request, :allow_freeform, true)
    show_freeform = allow_freeform || choices == []
    assigns = assign(assigns, choices: choices, show_freeform: show_freeform)

    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm"
      id="ask-user-modal"
      phx-window-keydown="ask_user_dismiss"
      phx-key="Escape"
    >
      <div class="bg-base-100 rounded-2xl shadow-2xl border border-base-300 w-full max-w-lg mx-4 overflow-hidden">
        <%!-- Header --%>
        <div class="flex items-center justify-between px-6 pt-5 pb-3">
          <div class="flex items-center gap-2">
            <span class="text-xl">❓</span>
            <h3 class="text-lg font-semibold text-base-content">Copilot needs your input</h3>
          </div>
          <button
            phx-click="ask_user_dismiss"
            class="btn btn-ghost btn-sm btn-circle text-base-content/50 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <%!-- Question --%>
        <div class="px-6 pb-4">
          <div
            class="text-base text-base-content leading-relaxed"
            id="ask-user-question"
            phx-hook="MarkdownContent"
            data-markdown={@request.question}
          >
          </div>
        </div>

        <%!-- Choices --%>
        <%= if @choices != [] do %>
          <div class="px-6 pb-3 space-y-2">
            <%= for choice <- @choices do %>
              <button
                phx-click="ask_user_select"
                phx-value-choice={choice}
                class="w-full text-left px-4 py-3 rounded-xl border border-base-300
                             bg-base-200/50 hover:bg-primary/10 hover:border-primary/50
                             transition-all duration-150 text-sm font-medium
                             active:scale-[0.98]"
              >
                {choice}
              </button>
            <% end %>
          </div>
        <% end %>

        <%!-- Freeform input --%>
        <%= if @show_freeform do %>
          <div class="px-6 pb-5">
            <%= if @choices != [] do %>
              <div class="divider text-xs text-base-content/40 my-2">or type your own</div>
            <% end %>
            <form phx-submit="ask_user_freeform_submit" class="flex gap-2">
              <input
                type="text"
                name="response"
                value={@freeform_text}
                phx-change="ask_user_freeform_change"
                placeholder="Type your answer..."
                class="input input-bordered flex-1 input-sm"
                autofocus={@choices == []}
              />
              <button
                type="submit"
                class="btn btn-primary btn-sm"
                disabled={String.trim(@freeform_text) == ""}
              >
                Send
              </button>
            </form>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Helpers ──

  defp build_checkpoint_entries(checkpoints, events) do
    compaction_index = build_compaction_index(events)

    Enum.map(checkpoints, fn checkpoint ->
      content = checkpoint.content || ""

      compaction =
        Map.get(compaction_index.by_number, checkpoint.number) ||
          Map.get(compaction_index.by_filename, checkpoint.filename)

      tokens = compaction && compaction.tokens

      %{
        id: checkpoint.id,
        number: checkpoint.number,
        title: checkpoint.title,
        filename: checkpoint.filename,
        content: content,
        compaction_event: compaction,
        compaction_success: compaction && compaction.success,
        compaction_path: compaction && compaction.checkpoint_path,
        compaction_timestamp: compaction && compaction.timestamp,
        compaction_tokens: tokens,
        compaction_input_tokens: tokens && tokens.input,
        compaction_output_tokens: tokens && tokens.output,
        compaction_cached_input_tokens: tokens && tokens.cached_input,
        pre_compaction_messages_length: compaction && compaction.pre_compaction_messages_length,
        pre_compaction_tokens: compaction && compaction.pre_compaction_tokens,
        request_id: compaction && compaction.request_id,
        summary_content: compaction && compaction.summary_content
      }
    end)
  end

  defp build_compaction_index(events) do
    Enum.reduce(events, %{by_number: %{}, by_filename: %{}}, fn event, acc ->
      if event.type == "session.compaction_complete" do
        data = event.data || %{}
        checkpoint_number = map_get_any(data, ["checkpointNumber", :checkpointNumber])
        checkpoint_path = map_get_any(data, ["checkpointPath", :checkpointPath])

        compaction = %{
          success: map_get_any(data, ["success", :success]) != false,
          checkpoint_path: checkpoint_path,
          timestamp: event.timestamp,
          tokens:
            normalize_compaction_tokens(
              map_get_any(data, ["compactionTokensUsed", :compactionTokensUsed]) || %{}
            ),
          pre_compaction_messages_length:
            map_get_any(data, ["preCompactionMessagesLength", :preCompactionMessagesLength]),
          pre_compaction_tokens: map_get_any(data, ["preCompactionTokens", :preCompactionTokens]),
          request_id: map_get_any(data, ["requestId", :requestId]),
          summary_content: map_get_any(data, ["summaryContent", :summaryContent])
        }

        acc =
          if is_integer(checkpoint_number) do
            put_in(acc, [:by_number, checkpoint_number], compaction)
          else
            acc
          end

        if is_binary(checkpoint_path) do
          put_in(acc, [:by_filename, Path.basename(checkpoint_path)], compaction)
        else
          acc
        end
      else
        acc
      end
    end)
  end

  defp normalize_compaction_tokens(tokens) do
    %{
      input: map_get_any(tokens, ["input", :input]) || 0,
      output: map_get_any(tokens, ["output", :output]) || 0,
      cached_input:
        map_get_any(tokens, ["cachedInput", :cachedInput, "cached_input", :cached_input]) || 0
    }
  end

  defp sort_artifacts(artifacts) do
    artifacts
    |> Enum.map(fn artifact ->
      %{
        id: artifact.id,
        path: artifact.path,
        content: artifact.content || "",
        content_hash: artifact.content_hash,
        size: artifact.size || 0,
        artifact_type: artifact.artifact_type
      }
    end)
    |> Enum.sort_by(&artifact_sort_key/1)
  end

  defp artifact_sort_key(artifact) do
    rank =
      case artifact.artifact_type do
        :plan -> 0
        :workspace -> 1
        :file -> 2
        :session_db_dump -> 3
        :codex_thread_meta -> 4
        _ -> 5
      end

    {rank, artifact.path || ""}
  end

  defp default_inspector_tab(checkpoints, _artifacts) when checkpoints != [], do: :checkpoints
  defp default_inspector_tab([], artifacts) when artifacts != [], do: :artifacts
  defp default_inspector_tab(_, _), do: :checkpoints

  defp default_checkpoint_id([]), do: nil
  defp default_checkpoint_id(checkpoints), do: checkpoints |> List.last() |> Map.get(:id)

  defp default_artifact_id([]), do: nil
  defp default_artifact_id([artifact | _]), do: artifact.id

  defp select_item(items, nil), do: List.first(items)
  defp select_item(items, id), do: Enum.find(items, &(Map.get(&1, :id) == id))

  defp preview_text(nil, _limit), do: "(empty)"

  defp preview_text(text, limit) when is_binary(text) do
    normalized =
      text
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      normalized == "" ->
        "(empty)"

      String.length(normalized) <= limit ->
        normalized

      true ->
        String.slice(normalized, 0, limit) <> "…"
    end
  end

  defp format_bytes(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp format_bytes(bytes) when bytes >= 1_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"

  defp format_datetime(nil), do: "Unknown time"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp artifact_type_label(:plan), do: "Plan"
  defp artifact_type_label(:workspace), do: "Workspace snapshot"
  defp artifact_type_label(:file), do: "Session file"
  defp artifact_type_label(:session_db_dump), do: "Session DB dump"
  defp artifact_type_label(:codex_thread_meta), do: "Codex thread metadata"

  defp artifact_type_label(other),
    do: other |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp status_badge(:idle), do: "badge-success"
  defp status_badge(:thinking), do: "badge-warning"
  defp status_badge(:tool_running), do: "badge-info"
  defp status_badge(:starting), do: "badge-neutral"
  defp status_badge(_), do: "badge-ghost"

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}m"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp format_tokens(n), do: "#{n}"

  defp format_multiplier(0), do: "free"
  defp format_multiplier(m), do: "#{m}x"

  defp map_get_any(%{__struct__: _} = struct, keys),
    do: map_get_any(Map.from_struct(struct), keys)

  defp map_get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_get_any(_, _keys), do: nil

  defp map_get(%{__struct__: _} = struct, key), do: Map.get(struct, key)
  defp map_get(map, key) when is_map(map), do: Map.get(map, key)

  # Detect @query pattern in prompt text for file autocomplete
  defp detect_at_mention(prompt, socket) do
    # Find the last @ that is preceded by space or at start of string,
    # allowing trailing whitespace after the query
    case Regex.run(~r/(?:^|(?<=\s))@([^\s]*)\s*$/, prompt) do
      [_full, query] ->
        # Don't trigger suggestions if this @mention is already a resolved file
        if Map.has_key?(socket.assigns.resolved_files, query) do
          {[], ""}
        else
          cwd = socket.assigns.cwd || "."
          resolved_paths = socket.assigns.resolved_files |> Map.values() |> MapSet.new(& &1.path)

          suggestions =
            list_files_matching(cwd, query)
            |> Enum.reject(&MapSet.member?(resolved_paths, &1.path))
            |> Enum.take(15)

          {suggestions, query}
        end

      _ ->
        {[], ""}
    end
  end

  # Replace the last occurrence of @query at the end of the prompt with the mention
  defp replace_last_at_query(prompt, query, mention) do
    target = "@" <> query
    # Find the last occurrence
    case :binary.matches(prompt, target) do
      [] ->
        prompt <> " " <> mention <> " "

      matches ->
        {pos, len} = List.last(matches)
        before = binary_part(prompt, 0, pos)
        rest = binary_part(prompt, pos + len, byte_size(prompt) - pos - len)
        before <> mention <> " " <> String.trim_leading(rest)
    end
  end

  # Extract inline @mentions from prompt text in order of appearance,
  # resolving them against the resolved_files map to build ordered attachments.
  defp extract_inline_attachments(_prompt, resolved_files) when map_size(resolved_files) == 0,
    do: {[], []}

  defp extract_inline_attachments(prompt, resolved_files) do
    # Find all @display_name references in the prompt, in order
    # Build a regex that matches any of the resolved display names
    names = Map.keys(resolved_files) |> Enum.sort_by(&(-String.length(&1)))
    escaped = Enum.map(names, &Regex.escape/1)
    pattern = Regex.compile!("(?:^|(?<=\\s))@(" <> Enum.join(escaped, "|") <> ")(?=\\s|$)")

    mentions =
      Regex.scan(pattern, prompt)
      |> Enum.map(fn [_full, name] -> name end)
      |> Enum.uniq()

    attachments =
      Enum.flat_map(mentions, fn name ->
        case Map.get(resolved_files, name) do
          nil ->
            []

          f ->
            [
              %Jido.GHCopilot.Server.Types.Attachment{
                type: String.to_existing_atom(f.type),
                path: f.path,
                display_name: f.display_name
              }
            ]
        end
      end)

    file_maps =
      Enum.flat_map(mentions, fn name ->
        case Map.get(resolved_files, name) do
          nil -> []
          f -> [%{"type" => f.type, "path" => f.path, "displayName" => f.display_name}]
        end
      end)

    {attachments, file_maps}
  end

  # File listing for @ mention autocomplete
  defp list_files_matching(cwd, query) do
    base = Path.expand(cwd)
    all_files = scan_directory(base, base, 3)

    if query == "" do
      # Show top-level entries when just @ is typed
      Enum.sort_by(all_files, & &1.display_name)
    else
      query_down = String.downcase(query)

      all_files
      |> Enum.filter(fn entry ->
        String.contains?(String.downcase(entry.display_name), query_down)
      end)
      |> Enum.sort_by(fn entry ->
        name_down = String.downcase(entry.display_name)

        cond do
          String.starts_with?(name_down, query_down) -> {0, entry.display_name}
          true -> {1, entry.display_name}
        end
      end)
    end
  end

  @ignored_dirs ~w[_build deps node_modules .elixir_ls .git]
  defp scan_directory(dir, base, max_depth, depth \\ 0) do
    if depth >= max_depth do
      []
    else
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.reject(&(&1 in @ignored_dirs))
          |> Enum.flat_map(fn name ->
            full = Path.join(dir, name)
            rel = Path.relative_to(full, base)

            case File.stat(full) do
              {:ok, %{type: :directory}} ->
                entry = %{path: full, type: "directory", display_name: rel <> "/"}
                [entry | scan_directory(full, base, max_depth, depth + 1)]

              {:ok, %{type: :regular}} ->
                [%{path: full, type: "file", display_name: rel}]

              _ ->
                []
            end
          end)

        _ ->
          []
      end
    end
  end

  defp resume_command(agent, hostname, cwd, session_id) do
    provider_id = CopilotLv.Sessions.Session.provider_id(session_id)

    ssh_prefix =
      if hostname && hostname not in [local_hostname(), nil], do: "ssh #{hostname} ", else: ""

    cd = "cd #{cwd}"

    agent_cmd =
      case agent do
        :claude ->
          "claude --dangerously-skip-permissions --resume #{provider_id}"

        :codex ->
          "codex --resume #{provider_id}"

        :gemini ->
          "gemini"

        _ ->
          "copilot --allow-all-tools --allow-all-paths --allow-all-urls --resume=#{provider_id}"
      end

    if ssh_prefix != "" do
      "#{ssh_prefix}\"#{cd} && #{agent_cmd}\""
    else
      "#{cd} && #{agent_cmd}"
    end
  end

  defp handoff_url(session_id) do
    endpoint_base_url() <> ~p"/api/sessions/#{session_id}/handoff.md"
  end

  defp handoff_prompt(session_id) do
    session_id
    |> handoff_url()
    |> SessionHandoff.takeover_prompt()
  end

  defp endpoint_base_url do
    uri = URI.parse(CopilotLvWeb.Endpoint.url())
    scheme = uri.scheme || "http"
    host = uri.host || "localhost"
    port = uri.port || endpoint_port()
    default_port = if scheme == "https", do: 443, else: 80

    if is_integer(port) && port != default_port do
      "#{scheme}://#{host}:#{port}"
    else
      "#{scheme}://#{host}"
    end
  end

  defp endpoint_port do
    CopilotLvWeb.Endpoint.config(:http)[:port]
  end

  defp local_hostname do
    case File.read("/etc/hostname") do
      {:ok, name} -> String.trim(name)
      _ -> "localhost"
    end
  end

  defp push_file_tokens(socket, events) do
    tokens =
      events
      |> Enum.flat_map(fn event ->
        # Collect text from top-level event and from nested events inside tool groups
        nested = get_in(event, [:data, "events"]) || []

        all_events = [event | nested]

        Enum.flat_map(all_events, fn evt ->
          data = evt[:data] || %{}

          [data["content"], data["result"], data["arguments"]]
          |> Enum.reject(&is_nil/1)
          |> Enum.flat_map(fn text ->
            CopilotLvWeb.FileViewer.scan_and_sign(CopilotLvWeb.Endpoint, text)
            |> Map.to_list()
          end)
        end)
      end)
      |> Map.new()

    if map_size(tokens) > 0 do
      push_event(socket, "file_tokens", %{tokens: tokens})
    else
      socket
    end
  end

  defp push_file_tokens_for_text(socket, text) when is_binary(text) do
    tokens = CopilotLvWeb.FileViewer.scan_and_sign(CopilotLvWeb.Endpoint, text)

    if map_size(tokens) > 0 do
      push_event(socket, "file_tokens", %{tokens: tokens})
    else
      socket
    end
  end

  # ── Pasted Content Parsing ──

  @pasted_content_re ~r/<pasted_content\s+file="([^"]*?)"\s+size="([^"]*?)"\s+lines="([^"]*?)"\s*\/>/

  @session_state_uuid_re ~r|/session-state/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/|

  @doc false
  defp parse_pasted_content(content) when is_binary(content) do
    attachments =
      Regex.scan(@pasted_content_re, content)
      |> Enum.map(fn [_full, file, size, lines] ->
        source_session_id = extract_session_id_from_path(file)

        %{
          "file" => file,
          "size" => size,
          "lines" => lines,
          "artifact_path" => "files/" <> Path.basename(file),
          "source_session_id" => source_session_id
        }
      end)

    cleaned = Regex.replace(@pasted_content_re, content, "")
    cleaned = String.trim(cleaned)

    {cleaned, attachments}
  end

  defp parse_pasted_content(content), do: {content, []}

  defp extract_session_id_from_path(path) do
    case Regex.run(@session_state_uuid_re, path) do
      [_, uuid] -> CopilotLv.Sessions.Session.prefixed_id(:copilot, uuid)
      _ -> nil
    end
  end

  defp enrich_user_message_with_pasted_content(%{type: "user.message", data: data} = event) do
    content = Map.get(data, "content", "")
    {cleaned, attachments} = parse_pasted_content(content)

    if attachments == [] do
      event
    else
      %{
        event
        | data: Map.merge(data, %{"content" => cleaned, "pasted_attachments" => attachments})
      }
    end
  end

  defp enrich_user_message_with_pasted_content(event), do: event

  # ── Paste File Management ──

  @session_state_dirs [
    Path.join(System.user_home!(), ".copilot/session-state"),
    Path.join(System.user_home!(), ".local/state/.copilot/session-state")
  ]

  defp resolve_session_files_dir(provider_id) do
    # Find the session state directory that exists for this provider_id
    session_dir =
      Enum.find_value(@session_state_dirs, fn base ->
        dir = Path.join(base, provider_id)
        if File.dir?(dir), do: dir
      end)

    case session_dir do
      nil ->
        # Session dir doesn't exist yet — create in the primary location
        primary = Path.join(hd(@session_state_dirs), provider_id)
        files_dir = Path.join(primary, "files")
        File.mkdir_p!(files_dir)
        {:ok, files_dir}

      dir ->
        files_dir = Path.join(dir, "files")
        File.mkdir_p!(files_dir)
        {:ok, files_dir}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
