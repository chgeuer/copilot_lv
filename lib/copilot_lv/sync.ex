defmodule CopilotLv.Sync do
  @moduledoc """
  Core sync logic for importing copilot CLI session history.
  Extracted from Mix.Tasks.Copilot.Sync for reuse in LiveView.
  """

  alias CopilotLv.SessionStoreImpl

  @session_state_dirs [
    Path.join(System.user_home!(), ".copilot/session-state"),
    Path.join(System.user_home!(), ".local/state/.copilot/session-state")
  ]

  @doc "Run a full sync, returns stats map."
  def run(opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)
    dry_run = Keyword.get(opts, :dry_run, false)

    active_dirs = Enum.filter(@session_state_dirs, &File.dir?/1)

    if active_dirs == [] do
      {:error,
       "No session state directories found. Checked: #{Enum.join(@session_state_dirs, ", ")}"}
    else
      session_dirs = list_session_dirs()
      standalone_jsonls = list_standalone_jsonls()
      {existing_ids, live_ids} = load_existing_session_ids()

      stats = %{
        imported: 0,
        updated: 0,
        skipped: 0,
        errors: 0,
        events: 0,
        checkpoints: 0,
        artifacts: 0,
        todos: 0
      }

      # Import sessions with directories
      stats =
        Enum.reduce(session_dirs, stats, fn {session_id, dir_path}, stats ->
          case sync_session(session_id, dir_path, existing_ids, live_ids, verbose, dry_run) do
            {:imported, event_count, cp_count, art_count, todo_count} ->
              %{
                stats
                | imported: stats.imported + 1,
                  events: stats.events + event_count,
                  checkpoints: stats.checkpoints + cp_count,
                  artifacts: stats.artifacts + art_count,
                  todos: stats.todos + todo_count
              }

            {:updated, event_count, cp_count, art_count, todo_count} ->
              %{
                stats
                | updated: stats.updated + 1,
                  events: stats.events + event_count,
                  checkpoints: stats.checkpoints + cp_count,
                  artifacts: stats.artifacts + art_count,
                  todos: stats.todos + todo_count
              }

            :skipped ->
              %{stats | skipped: stats.skipped + 1}

            {:error, _reason} ->
              %{stats | errors: stats.errors + 1}
          end
        end)

      # Import standalone .jsonl files (old format, no directory)
      stats =
        Enum.reduce(standalone_jsonls, stats, fn {session_id, jsonl_path}, stats ->
          case sync_standalone_jsonl(session_id, jsonl_path, existing_ids, live_ids, dry_run) do
            {:imported, event_count} ->
              %{stats | imported: stats.imported + 1, events: stats.events + event_count}

            :skipped ->
              %{stats | skipped: stats.skipped + 1}

            {:error, _reason} ->
              %{stats | errors: stats.errors + 1}
          end
        end)

      {:ok, stats}
    end
  end

  # ── Session Directory Scanning ──

  defp list_session_dirs do
    list_session_dirs(@session_state_dirs)
  end

  defp list_session_dirs(dirs) do
    dirs
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn base_dir ->
      base_dir
      |> File.ls!()
      |> Enum.filter(fn name ->
        path = Path.join(base_dir, name)
        File.dir?(path) && valid_uuid?(name)
      end)
      |> Enum.map(fn name -> {name, Path.join(base_dir, name)} end)
    end)
    |> Enum.uniq_by(fn {id, _} -> id end)
    |> Enum.sort()
  end

  defp list_standalone_jsonls do
    list_standalone_jsonls(@session_state_dirs)
  end

  defp list_standalone_jsonls(dirs) do
    dirs
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn base_dir ->
      base_dir
      |> File.ls!()
      |> Enum.filter(fn name ->
        String.ends_with?(name, ".jsonl") &&
          valid_uuid?(String.trim_trailing(name, ".jsonl")) &&
          !File.dir?(Path.join(base_dir, String.trim_trailing(name, ".jsonl")))
      end)
      |> Enum.map(fn name ->
        session_id = String.trim_trailing(name, ".jsonl")
        {session_id, Path.join(base_dir, name)}
      end)
    end)
    |> Enum.uniq_by(fn {id, _} -> id end)
    |> Enum.sort()
  end

  defp valid_uuid?(name) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, name)
  end

  defp load_existing_session_ids do
    sessions = SessionStoreImpl.list_sessions([])

    # Extract provider IDs from prefixed session IDs for copilot sessions
    all_ids =
      sessions
      |> Enum.filter(&(&1.agent == :copilot || is_nil(&1.agent)))
      |> Enum.map(&CopilotLv.Sessions.Session.provider_id(&1.id))
      |> MapSet.new()

    live_ids =
      sessions
      |> Enum.reject(&(&1.source == :imported))
      |> Enum.filter(&(&1.agent == :copilot || is_nil(&1.agent)))
      |> Enum.map(&CopilotLv.Sessions.Session.provider_id(&1.id))
      |> MapSet.new()

    {all_ids, live_ids}
  end

  # ── Per-Session Sync ──

  defp sync_session(session_id, dir_path, existing_ids, live_ids, _verbose, dry_run) do
    workspace = read_workspace(dir_path)
    events_path = Path.join(dir_path, "events.jsonl")

    cond do
      MapSet.member?(live_ids, session_id) ->
        :skipped

      !File.exists?(events_path) ->
        :skipped

      MapSet.member?(existing_ids, session_id) ->
        sync_existing_session(session_id, dir_path, workspace, dry_run)

      true ->
        import_new_session(session_id, dir_path, workspace, dry_run)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp import_new_session(session_id, dir_path, workspace, dry_run) do
    events_path = Path.join(dir_path, "events.jsonl")
    raw_events = read_events(events_path)

    if Enum.empty?(raw_events) do
      :skipped
    else
      session_start = List.first(raw_events)
      context = get_in(session_start, ["data", "context"]) || %{}
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

      prefixed_id = CopilotLv.Sessions.Session.prefixed_id(:copilot, session_id)

      if dry_run do
        checkpoints = read_checkpoints(dir_path)
        artifacts = read_artifacts(dir_path)
        todos = read_session_todos(dir_path)
        {:imported, length(raw_events), length(checkpoints), length(artifacts), length(todos)}
      else
        jido_session = %JidoSessions.Session{
          id: prefixed_id,
          agent: :copilot,
          source: :imported,
          status: :stopped,
          cwd: workspace["cwd"] || context["cwd"] || "unknown",
          model: get_in(session_start, ["data", "selectedModel"]),
          summary: summary,
          title: title,
          git_root: workspace["git_root"] || context["gitRoot"],
          branch: workspace["branch"] || context["branch"],
          agent_version: get_in(session_start, ["data", "copilotVersion"]),
          started_at: parse_timestamp(workspace["created_at"] || session_start["timestamp"]),
          stopped_at: parse_timestamp(workspace["updated_at"])
        }

        {:ok, _} = SessionStoreImpl.upsert_session(jido_session)

        event_count = import_events(prefixed_id, raw_events)
        checkpoints = read_checkpoints(dir_path)
        cp_count = import_checkpoints(prefixed_id, checkpoints)
        artifacts = read_artifacts(dir_path)
        art_count = import_artifacts(prefixed_id, artifacts)
        todos = read_session_todos(dir_path)
        todo_count = import_session_todos(prefixed_id, todos)
        {:imported, event_count, cp_count, art_count, todo_count}
      end
    end
  end

  defp sync_existing_session(session_id, dir_path, workspace, dry_run) do
    events_path = Path.join(dir_path, "events.jsonl")
    raw_events = read_events(events_path)
    prefixed_id = CopilotLv.Sessions.Session.prefixed_id(:copilot, session_id)

    case SessionStoreImpl.get_session(prefixed_id) do
      {:ok, existing} ->
        existing_event_count = SessionStoreImpl.event_count(prefixed_id)
        _new_event_count = length(raw_events)

        summary = workspace["summary"] || existing.summary

        title =
          if summary do
            summary
            |> String.split("\n")
            |> hd()
            |> String.trim_leading("# ")
            |> String.trim()
            |> String.slice(0, 120)
          else
            existing.title
          end

        # Always sync artifacts and todos for existing sessions (idempotent upsert)
        artifacts = read_artifacts(dir_path)
        todos = read_session_todos(dir_path)

        if dry_run do
          new_events = Enum.drop(raw_events, existing_event_count)
          {:updated, length(new_events), 0, length(artifacts), length(todos)}
        else
          new_events = Enum.drop(raw_events, existing_event_count)

          event_count =
            if new_events != [] do
              import_events(prefixed_id, new_events, existing_event_count)
            else
              0
            end

          art_count = import_artifacts(prefixed_id, artifacts)
          todo_count = import_session_todos(prefixed_id, todos)

          # Update session metadata
          updated_session = %JidoSessions.Session{existing | summary: summary, title: title}
          SessionStoreImpl.upsert_session(updated_session)

          has_changes = event_count > 0 || art_count > 0 || todo_count > 0

          if has_changes do
            {:updated, event_count, 0, art_count, todo_count}
          else
            :skipped
          end
        end

      {:error, :not_found} ->
        :skipped
    end
  end

  # ── File Reading ──

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

  defp read_events(events_path) do
    events_path
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

  defp read_checkpoints(dir_path) do
    cp_dir = Path.join(dir_path, "checkpoints")

    if File.dir?(cp_dir) do
      cp_dir
      |> File.ls!()
      |> Enum.filter(&(String.ends_with?(&1, ".md") && &1 != "index.md"))
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Enum.map(fn {filename, index} ->
        content = File.read!(Path.join(cp_dir, filename))

        title =
          filename
          |> String.trim_trailing(".md")
          |> String.replace(~r/^\d+-/, "")
          |> String.replace("-", " ")
          |> String.split()
          |> Enum.map_join(" ", &String.capitalize/1)

        number =
          case Regex.run(~r/^(\d+)/, filename) do
            [_, n] -> String.to_integer(n)
            _ -> index
          end

        %{number: number, title: title, filename: filename, content: content}
      end)
    else
      []
    end
  end

  defp read_artifacts(dir_path) do
    artifacts = []

    # plan.md
    plan_path = Path.join(dir_path, "plan.md")

    artifacts =
      if File.exists?(plan_path) do
        content = File.read!(plan_path)
        [make_artifact("plan.md", content, :plan) | artifacts]
      else
        artifacts
      end

    # workspace.yaml (raw content for round-trip)
    ws_path = Path.join(dir_path, "workspace.yaml")

    artifacts =
      if File.exists?(ws_path) do
        content = File.read!(ws_path)
        [make_artifact("workspace.yaml", content, :workspace) | artifacts]
      else
        artifacts
      end

    # files/* directory
    files_dir = Path.join(dir_path, "files")

    artifacts =
      if File.dir?(files_dir) do
        file_artifacts =
          files_dir
          |> File.ls!()
          |> Enum.filter(&(!File.dir?(Path.join(files_dir, &1))))
          |> Enum.map(fn filename ->
            content = File.read!(Path.join(files_dir, filename))
            make_artifact("files/#{filename}", content, :file)
          end)

        file_artifacts ++ artifacts
      else
        artifacts
      end

    # session.db custom tables (non-standard tables serialized as JSON)
    db_path = Path.join(dir_path, "session.db")

    artifacts =
      if File.exists?(db_path) do
        case read_custom_db_tables(db_path) do
          [] -> artifacts
          tables -> [make_db_dump_artifact(tables) | artifacts]
        end
      else
        artifacts
      end

    artifacts
  end

  defp make_artifact(path, content, type) do
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %{
      path: path,
      content: content,
      content_hash: hash,
      artifact_type: type,
      size: byte_size(content)
    }
  end

  defp make_db_dump_artifact(tables) do
    content = Jason.encode!(tables, pretty: true)
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %{
      path: "session.db.json",
      content: content,
      content_hash: hash,
      artifact_type: :session_db_dump,
      size: byte_size(content)
    }
  end

  defp read_custom_db_tables(db_path) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path, mode: :readonly)

    try do
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT IN ('todos', 'todo_deps')"
        )

      tables = fetch_all_rows(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)

      Enum.flat_map(tables, fn [table_name] ->
        {:ok, ddl_stmt} =
          Exqlite.Sqlite3.prepare(
            conn,
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?1"
          )

        :ok = Exqlite.Sqlite3.bind(ddl_stmt, [table_name])
        [[ddl]] = fetch_all_rows(conn, ddl_stmt)
        Exqlite.Sqlite3.release(conn, ddl_stmt)

        {:ok, data_stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT * FROM \"#{table_name}\"")
        {:ok, columns} = Exqlite.Sqlite3.columns(conn, data_stmt)
        rows = fetch_all_rows(conn, data_stmt)
        Exqlite.Sqlite3.release(conn, data_stmt)

        data = Enum.map(rows, fn row -> Enum.zip(columns, row) |> Map.new() end)

        [%{table: table_name, ddl: ddl, data: data}]
      end)
    after
      Exqlite.Sqlite3.close(conn)
    end
  rescue
    _ -> []
  end

  defp read_session_todos(dir_path) do
    db_path = Path.join(dir_path, "session.db")

    if File.exists?(db_path) do
      {:ok, conn} = Exqlite.Sqlite3.open(db_path, mode: :readonly)

      try do
        # Read todos
        {:ok, stmt} =
          Exqlite.Sqlite3.prepare(conn, "SELECT id, title, description, status FROM todos")

        todo_rows = fetch_all_rows(conn, stmt)
        Exqlite.Sqlite3.release(conn, stmt)

        # Read deps
        {:ok, dep_stmt} =
          Exqlite.Sqlite3.prepare(conn, "SELECT todo_id, depends_on FROM todo_deps")

        dep_rows = fetch_all_rows(conn, dep_stmt)
        Exqlite.Sqlite3.release(conn, dep_stmt)

        deps_map =
          Enum.group_by(dep_rows, fn [todo_id, _] -> todo_id end, fn [_, dep] -> dep end)

        Enum.map(todo_rows, fn [id, title, description, status] ->
          %{
            todo_id: id,
            title: title || "(untitled)",
            description: description,
            status: status || "pending",
            depends_on: Map.get(deps_map, id, [])
          }
        end)
      after
        Exqlite.Sqlite3.close(conn)
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp fetch_all_rows(conn, stmt) do
    fetch_all_rows(conn, stmt, [])
  end

  defp fetch_all_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  # ── Standalone .jsonl Import ──

  defp sync_standalone_jsonl(session_id, jsonl_path, existing_ids, live_ids, dry_run) do
    cond do
      MapSet.member?(live_ids, session_id) -> :skipped
      MapSet.member?(existing_ids, session_id) -> :skipped
      true -> import_standalone_jsonl(session_id, jsonl_path, dry_run)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp import_standalone_jsonl(session_id, jsonl_path, dry_run) do
    raw_events = read_events(jsonl_path)

    if Enum.empty?(raw_events) do
      :skipped
    else
      session_start = List.first(raw_events)
      context = get_in(session_start, ["data", "context"]) || %{}
      prefixed_id = CopilotLv.Sessions.Session.prefixed_id(:copilot, session_id)

      if dry_run do
        {:imported, length(raw_events)}
      else
        jido_session = %JidoSessions.Session{
          id: prefixed_id,
          agent: :copilot,
          source: :imported,
          status: :stopped,
          cwd: context["cwd"] || "unknown",
          model: get_in(session_start, ["data", "selectedModel"]),
          git_root: context["gitRoot"],
          branch: context["branch"],
          agent_version: get_in(session_start, ["data", "copilotVersion"]),
          started_at: parse_timestamp(session_start["timestamp"])
        }

        {:ok, _} = SessionStoreImpl.upsert_session(jido_session)

        event_count = import_events(prefixed_id, raw_events)
        {:imported, event_count}
      end
    end
  end

  # ── Data Import ──

  defp import_events(session_id, raw_events, offset \\ 0) do
    entries =
      raw_events
      |> Enum.with_index(offset + 1)
      |> Enum.map(fn {event, seq} ->
        %{
          type: event["type"] || "unknown",
          data: event["data"] || %{},
          timestamp: parse_timestamp(event["timestamp"]),
          sequence: seq,
          event_id: event["id"],
          parent_event_id: event["parentId"]
        }
      end)

    {:ok, _count} = SessionStoreImpl.insert_events(session_id, entries)
    length(raw_events)
  end

  defp import_checkpoints(session_id, checkpoints) do
    unless Enum.empty?(checkpoints) do
      cp_structs =
        Enum.map(checkpoints, fn cp ->
          %JidoSessions.Checkpoint{
            number: cp.number,
            title: cp.title,
            filename: cp.filename,
            content: cp.content
          }
        end)

      SessionStoreImpl.insert_checkpoints(session_id, cp_structs)
    end

    length(checkpoints)
  end

  defp import_artifacts(session_id, artifacts) do
    unless Enum.empty?(artifacts) do
      art_structs =
        Enum.map(artifacts, fn art ->
          %JidoSessions.Artifact{
            path: art.path,
            artifact_type: art.artifact_type,
            content: art.content,
            content_hash: art.content_hash,
            size: art.size
          }
        end)

      SessionStoreImpl.upsert_artifacts(session_id, art_structs)
    end

    length(artifacts)
  end

  defp import_session_todos(session_id, todos) do
    unless Enum.empty?(todos) do
      todo_structs =
        Enum.map(todos, fn todo ->
          %JidoSessions.Todo{
            todo_id: todo.todo_id,
            title: todo.title,
            description: todo.description,
            status: parse_todo_status(todo.status),
            depends_on: todo.depends_on || []
          }
        end)

      SessionStoreImpl.upsert_todos(session_id, todo_structs)
    end

    length(todos)
  end

  # ── Helpers ──

  defp parse_todo_status("pending"), do: :pending
  defp parse_todo_status("in_progress"), do: :in_progress
  defp parse_todo_status("done"), do: :done
  defp parse_todo_status("blocked"), do: :blocked
  defp parse_todo_status(status) when is_atom(status), do: status
  defp parse_todo_status(_), do: :pending

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_timestamp(_), do: nil
end
