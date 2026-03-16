defmodule CopilotLv.Agents.Copilot do
  @moduledoc """
  Agent parser for GitHub Copilot CLI sessions.
  Wraps the existing discovery logic from CopilotLv.Sync.
  """

  @behaviour CopilotLv.Agents

  @impl true
  def agent_type, do: :copilot

  @impl true
  def remote_well_known_dirs do
    ["~/.local/state/.copilot/session-state", "~/.copilot/session-state"]
  end

  @impl true
  def well_known_dirs do
    [
      Path.expand("~/.copilot/session-state"),
      Path.expand("~/.local/state/.copilot/session-state")
    ]
  end

  @impl true
  def discover_sessions(base_dir) do
    if File.dir?(base_dir) do
      entries = File.ls!(base_dir)

      # Session directories (UUID-named dirs with events.jsonl)
      dirs =
        entries
        |> Enum.filter(fn name ->
          File.dir?(Path.join(base_dir, name)) && valid_uuid?(name)
        end)
        |> Enum.map(fn name -> {name, Path.join(base_dir, name)} end)

      # Standalone .jsonl files (no matching directory)
      dir_names = Enum.map(dirs, &elem(&1, 0)) |> MapSet.new()

      jsonls =
        entries
        |> Enum.filter(fn name ->
          String.ends_with?(name, ".jsonl") &&
            valid_uuid?(String.trim_trailing(name, ".jsonl")) &&
            !MapSet.member?(dir_names, String.trim_trailing(name, ".jsonl"))
        end)
        |> Enum.map(fn name ->
          sid = String.trim_trailing(name, ".jsonl")
          {sid, Path.join(base_dir, name)}
        end)

      (dirs ++ jsonls) |> Enum.sort()
    else
      []
    end
  end

  @impl true
  def parse_session(path) do
    cond do
      # Standalone .jsonl file (older copilot format, or remote hosts)
      String.ends_with?(path, ".jsonl") && File.regular?(path) ->
        parse_standalone_jsonl(path)

      # Directory with events.jsonl inside
      File.dir?(path) ->
        parse_session_dir(path)

      true ->
        {:error, :no_events_file}
    end
  end

  defp parse_session_dir(dir_path) do
    events_path = Path.join(dir_path, "events.jsonl")

    unless File.exists?(events_path) do
      {:error, :no_events_file}
    else
      raw_events = read_jsonl(events_path)

      if Enum.empty?(raw_events) do
        {:error, :empty_session}
      else
        session_id = Path.basename(dir_path)
        session_start = List.first(raw_events)
        context = get_in(session_start, ["data", "context"]) || %{}
        workspace = read_workspace(dir_path)
        build_parsed_session(session_id, raw_events, context, workspace)
      end
    end
  end

  defp parse_standalone_jsonl(jsonl_path) do
    raw_events = read_jsonl(jsonl_path)

    if Enum.empty?(raw_events) do
      {:error, :empty_session}
    else
      session_id = Path.basename(jsonl_path, ".jsonl")
      session_start = List.first(raw_events)
      context = get_in(session_start, ["data", "context"]) || %{}
      build_parsed_session(session_id, raw_events, context, %{})
    end
  end

  defp build_parsed_session(session_id, raw_events, context, workspace) do
    session_start = List.first(raw_events)
    summary = workspace["summary"]

    title =
      if summary do
        summary
        |> String.split("\n")
        |> hd()
        |> String.trim_leading("# ")
        |> String.trim()
        |> String.slice(0, 120)
      end

    events =
      raw_events
      |> Enum.with_index(1)
      |> Enum.map(fn {event, seq} ->
        %{
          type: event["type"] || "unknown",
          data: event,
          timestamp: parse_timestamp(event["timestamp"]),
          sequence: seq
        }
      end)

    {:ok,
     %{
       session_id: session_id,
       cwd: workspace["cwd"] || context["cwd"],
       model: get_in(session_start, ["data", "selectedModel"]),
       summary: summary,
       title: title,
       git_root: workspace["git_root"] || context["gitRoot"],
       branch: workspace["branch"] || context["branch"],
       agent_version: get_in(session_start, ["data", "copilotVersion"]),
       started_at: parse_timestamp(workspace["created_at"] || session_start["timestamp"]),
       stopped_at: parse_timestamp(workspace["updated_at"]),
       events: events
     }}
  end

  defp read_workspace(dir_path) do
    ws_path = Path.join(dir_path, "workspace.yaml")

    if File.exists?(ws_path) do
      ws_path |> File.read!() |> YamlElixir.read_from_string!()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp read_jsonl(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(fn line ->
      case Jason.decode(line) do
        {:ok, event} -> event
        {:error, _} -> nil
      end
    end)
    |> Stream.reject(&is_nil/1)
    |> Enum.to_list()
  end

  defp valid_uuid?(name) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, name)
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
