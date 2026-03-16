defmodule CopilotLv.Agents.Claude do
  @moduledoc """
  Agent parser for Claude Code CLI sessions.

  Claude stores sessions as JSONL files under ~/.claude/projects/{encoded-path}/.
  Each project directory name encodes the working directory path
  (e.g., `-home-user-src-work-myapp` → `/home/user/src/work/myapp`).
  """

  @behaviour CopilotLv.Agents

  @impl true
  def agent_type, do: :claude

  @impl true
  def remote_well_known_dirs do
    ["~/.claude/projects", "~/.claude-*/projects"]
  end

  @impl true
  def well_known_dirs do
    home = System.user_home!()

    # Find all .claude* directories (symlinks, renamed profiles like .claude-user@email)
    home
    |> File.ls!()
    |> Enum.filter(fn name ->
      String.starts_with?(name, ".claude") && !String.ends_with?(name, ".json")
    end)
    |> Enum.map(fn name ->
      # Resolve symlinks at the .claude* level so ~/.claude and its target deduplicate
      real_dir =
        case File.read_link(Path.join(home, name)) do
          {:ok, target} -> Path.expand(target, home)
          {:error, _} -> Path.join(home, name)
        end

      Path.join(real_dir, "projects")
    end)
    |> Enum.filter(&File.dir?/1)
    |> Enum.uniq()
  end

  @impl true
  def discover_sessions(base_dir) do
    if File.dir?(base_dir) do
      base_dir
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(base_dir, &1)))
      |> Enum.flat_map(fn project_dir ->
        project_path = Path.join(base_dir, project_dir)

        project_path
        |> File.ls!()
        |> Enum.filter(fn name ->
          String.ends_with?(name, ".jsonl") && name != "sessions-index.json"
        end)
        |> Enum.map(fn name ->
          session_id = String.trim_trailing(name, ".jsonl")
          {session_id, Path.join(project_path, name)}
        end)
      end)
      |> Enum.sort()
    else
      []
    end
  end

  @impl true
  def parse_session(jsonl_path) do
    lines = read_jsonl(jsonl_path)

    if Enum.empty?(lines) do
      {:error, :empty_session}
    else
      session_id = jsonl_path |> Path.basename() |> String.trim_trailing(".jsonl")
      project_dir = jsonl_path |> Path.dirname() |> Path.basename()
      cwd = decode_project_dir(project_dir)

      {summary, messages, metadata} = extract_claude_data(lines)

      first_user = Enum.find(messages, &(&1.type == :user))
      last_msg = List.last(messages)

      title =
        cond do
          summary -> summary |> String.slice(0, 120)
          first_user -> first_user.text |> String.slice(0, 120)
          true -> nil
        end

      # Store ALL raw lines for round-trip fidelity
      events =
        lines
        |> Enum.with_index(1)
        |> Enum.map(fn {raw_line, seq} ->
          %{
            type: raw_line["type"] || "unknown",
            data: raw_line,
            timestamp: parse_timestamp(raw_line["timestamp"]),
            sequence: seq
          }
        end)

      {:ok,
       %{
         session_id: session_id,
         cwd: cwd || metadata[:cwd],
         model: metadata[:model],
         summary: summary,
         title: title,
         git_root: nil,
         branch: metadata[:git_branch],
         agent_version: metadata[:version],
         started_at: first_user && first_user.timestamp,
         stopped_at: last_msg && last_msg.timestamp,
         events: events
       }}
    end
  end

  defp extract_claude_data(lines) do
    summary =
      Enum.find_value(lines, fn
        %{"type" => "summary", "summary" => s} when is_binary(s) -> s
        _ -> nil
      end)

    metadata =
      Enum.reduce(lines, %{}, fn line, acc ->
        case line do
          %{"type" => "user", "cwd" => cwd} when is_binary(cwd) ->
            Map.put(acc, :cwd, cwd)

          %{"type" => "user", "version" => v} when is_binary(v) ->
            Map.put(acc, :version, v)

          %{"type" => "user", "gitBranch" => b} when is_binary(b) ->
            Map.put(acc, :git_branch, b)

          %{"type" => "system", "message" => %{"content" => content}} when is_list(content) ->
            model = extract_model_from_system(content)
            if model, do: Map.put(acc, :model, model), else: acc

          _ ->
            acc
        end
      end)

    messages =
      lines
      |> Enum.reject(fn line ->
        line["type"] in ["file-history-snapshot", "summary"] || is_nil(line["type"])
      end)
      |> Enum.map(&normalize_claude_message/1)
      |> Enum.reject(&is_nil/1)

    {summary, messages, metadata}
  end

  defp normalize_claude_message(%{"type" => "user", "message" => msg} = line)
       when is_map(msg) do
    text =
      case msg do
        %{"content" => content} when is_binary(content) -> content
        %{"content" => content} when is_list(content) -> extract_text_blocks(content)
        _ -> nil
      end

    %{
      type: :user,
      text: text,
      timestamp: parse_timestamp(line["timestamp"]),
      data: line
    }
  end

  defp normalize_claude_message(%{"type" => "assistant", "message" => msg} = line)
       when is_map(msg) do
    text =
      case msg do
        %{"content" => content} when is_list(content) -> extract_text_blocks(content)
        %{"content" => content} when is_binary(content) -> content
        _ -> nil
      end

    %{
      type: :assistant,
      text: text,
      timestamp: parse_timestamp(line["timestamp"]),
      data: line
    }
  end

  defp normalize_claude_message(%{"type" => type} = line) do
    %{
      type: String.to_atom(type),
      text: nil,
      timestamp: parse_timestamp(line["timestamp"]),
      data: line
    }
  end

  defp normalize_claude_message(_), do: nil

  defp extract_text_blocks(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp extract_model_from_system(content) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        cond do
          String.contains?(text, "opus") -> "opus"
          String.contains?(text, "sonnet") -> "sonnet"
          String.contains?(text, "haiku") -> "haiku"
          true -> nil
        end

      _ ->
        nil
    end)
  end

  defp extract_model_from_system(_), do: nil

  @doc """
  Decodes a Claude project directory name back to a filesystem path.

  Example: `-home-user-src-work` → `/home/user/src/work`
  """
  def decode_project_dir(dir_name) do
    dir_name
    |> String.trim_leading("-")
    |> String.replace("-", "/")
    |> then(&("/" <> &1))
  end

  defp read_jsonl(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(fn line ->
      case Jason.decode(line) do
        {:ok, data} -> data
        {:error, _} -> nil
      end
    end)
    |> Stream.reject(&is_nil/1)
    |> Enum.to_list()
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
