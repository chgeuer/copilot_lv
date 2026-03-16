defmodule CopilotLv.Agents.Gemini do
  @moduledoc """
  Agent parser for Google Gemini CLI sessions.

  Gemini stores sessions as individual JSON files under
  ~/.gemini/tmp/{project-hash}/chats/session-{date}-{short-id}.json.
  Each file contains a `messages` array.
  """

  @behaviour CopilotLv.Agents

  @impl true
  def agent_type, do: :gemini

  @impl true
  def remote_well_known_dirs do
    ["~/.gemini/tmp"]
  end

  @impl true
  def well_known_dirs do
    [Path.expand("~/.gemini/tmp")]
  end

  @impl true
  def discover_sessions(base_dir) do
    if File.dir?(base_dir) do
      base_dir
      |> find_session_files()
      |> Enum.map(fn path ->
        session_id = extract_session_id(path)
        {session_id, path}
      end)
      |> Enum.sort()
    else
      []
    end
  end

  @impl true
  def parse_session(json_path) do
    with {:ok, content} <- File.read(json_path),
         {:ok, data} <- Jason.decode(content) do
      session_id = data["sessionId"] || extract_session_id(json_path)
      messages = data["messages"] || []

      if Enum.empty?(messages) do
        {:error, :empty_session}
      else
        parsed_messages = Enum.map(messages, &normalize_message/1)
        first_user = Enum.find(parsed_messages, &(&1.type == :user))

        # Store session envelope as first event, then each raw message
        session_envelope = Map.drop(data, ["messages"])

        events =
          [{session_envelope, 0} | Enum.with_index(messages, 1)]
          |> Enum.map(fn {raw_msg, seq} ->
            type =
              cond do
                seq == 0 -> "session_meta"
                is_binary(raw_msg["type"]) -> raw_msg["type"]
                true -> "unknown"
              end

            %{
              type: type,
              data: raw_msg,
              timestamp: parse_timestamp(raw_msg["timestamp"]),
              sequence: seq
            }
          end)

        first_ts = parse_timestamp(data["startTime"])
        last_ts = parse_timestamp(data["lastUpdated"])

        {:ok,
         %{
           session_id: session_id,
           cwd: decode_project_hash_to_cwd(json_path),
           model: extract_model(messages),
           summary: first_user && first_user.text,
           title: first_user && first_user.text && String.slice(first_user.text, 0, 120),
           git_root: nil,
           branch: nil,
           agent_version: nil,
           started_at: first_ts,
           stopped_at: last_ts,
           events: events
         }}
      end
    end
  end

  defp find_session_files(base_dir) do
    base_dir
    |> Path.join("*/chats/session-*.json")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp extract_session_id(path) do
    basename = Path.basename(path, ".json")

    case Regex.run(~r/session-[\d\-T]+-([0-9a-f]+)$/, basename) do
      [_, short_id] -> short_id
      _ -> basename
    end
  end

  defp normalize_message(%{"type" => "user", "content" => content} = msg) do
    %{
      type: :user,
      text: normalize_content(content),
      timestamp: parse_timestamp(msg["timestamp"]),
      data: msg
    }
  end

  defp normalize_message(%{"type" => "assistant", "content" => content} = msg) do
    %{
      type: :assistant,
      text: normalize_content(content),
      timestamp: parse_timestamp(msg["timestamp"]),
      data: msg
    }
  end

  defp normalize_message(%{"type" => type} = msg) do
    %{
      type: String.to_existing_atom(type),
      text: normalize_content(msg["content"]),
      timestamp: parse_timestamp(msg["timestamp"]),
      data: msg
    }
  rescue
    ArgumentError ->
      %{
        type: :info,
        text: normalize_content(msg["content"]),
        timestamp: parse_timestamp(msg["timestamp"]),
        data: msg
      }
  end

  defp normalize_message(msg) do
    %{
      type: :unknown,
      text: nil,
      timestamp: nil,
      data: msg
    }
  end

  defp normalize_content(content) when is_binary(content), do: content

  defp normalize_content(parts) when is_list(parts) do
    parts
    |> Enum.map_join("", fn
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp normalize_content(_), do: nil

  defp extract_model(messages) do
    Enum.find_value(messages, fn
      %{"model" => model} when is_binary(model) -> model
      _ -> nil
    end)
  end

  defp decode_project_hash_to_cwd(json_path) do
    # Gemini uses a project hash for the directory.
    # We can try to read the logs.json for CWD info.
    project_dir = json_path |> Path.dirname() |> Path.dirname()
    logs_path = Path.join(project_dir, "logs.json")

    if File.exists?(logs_path) do
      case File.read(logs_path)
           |> then(fn
             {:ok, c} -> Jason.decode(c)
             e -> e
           end) do
        {:ok, %{"cwd" => cwd}} when is_binary(cwd) -> cwd
        _ -> nil
      end
    end
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil
end
