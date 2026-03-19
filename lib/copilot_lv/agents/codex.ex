defmodule CopilotLv.Agents.Codex do
  @moduledoc """
  Agent parser for OpenAI Codex CLI sessions.

  Codex stores sessions in two places:
  - JSONL rollout files under `~/.codex/sessions/{year}/{month}/{day}/`
  - A SQLite database (`~/.codex/state_N.sqlite`) with a `threads` table

  Discovery uses both sources: the threads table is the canonical list,
  and JSONL glob catches any files not yet in the DB.
  """

  require Logger

  @behaviour JidoSessions.AgentParser

  @codex_dir Path.expand("~/.codex")

  @impl true
  def agent_type, do: :codex

  @impl true
  def remote_well_known_dirs do
    ["~/.codex/sessions"]
  end

  @impl true
  def well_known_dirs do
    [Path.expand("~/.codex/sessions")]
  end

  @impl true
  def discover_sessions(base_dir) do
    # Source 1: JSONL files on disk (original approach)
    jsonl_sessions =
      if File.dir?(base_dir) do
        base_dir
        |> find_jsonl_files()
        |> Map.new(fn path ->
          session_id = extract_session_id(path)
          {session_id, path}
        end)
      else
        %{}
      end

    # Source 2: threads table in state_N.sqlite (authoritative)
    db_sessions = discover_from_state_db()

    # Merge: DB sessions take precedence for rollout_path, JSONL fills gaps
    merged =
      Map.merge(jsonl_sessions, db_sessions, fn _id, _jsonl_path, db_path ->
        db_path
      end)

    merged
    |> Enum.map(fn {id, path} -> {id, path} end)
    |> Enum.sort()
  end

  @impl true
  def parse_session(jsonl_path) do
    session_id = extract_session_id(jsonl_path)
    db_meta = read_thread_metadata(session_id)

    if File.exists?(jsonl_path) do
      parse_from_jsonl(jsonl_path, session_id, db_meta)
    else
      parse_from_metadata_only(session_id, db_meta)
    end
  end

  defp parse_from_jsonl(jsonl_path, session_id, db_meta) do
    lines = read_jsonl(jsonl_path)

    if Enum.empty?(lines) do
      parse_from_metadata_only(session_id, db_meta)
    else
      session_meta = find_session_meta(lines)
      payload = (session_meta && session_meta["payload"]) || %{}
      git = payload["git"] || %{}

      events =
        lines
        |> Enum.reject(&redundant_event_msg?/1)
        |> Enum.with_index(1)
        |> Enum.map(fn {line, seq} ->
          %{
            type: line["type"] || "unknown",
            data: line,
            timestamp: parse_timestamp(line["timestamp"]),
            sequence: seq
          }
        end)

      first_ts = List.first(events) && List.first(events).timestamp
      last_ts = List.last(events) && List.last(events).timestamp

      user_text = extract_first_user_message(lines)

      # Enrich with DB metadata when available
      raw_title = db_meta[:title] || user_text
      title = raw_title && String.slice(raw_title, 0, 120)
      branch = db_meta[:git_branch] || git["branch"]

      {:ok,
       %{
         session_id: session_id,
         cwd: payload["cwd"] || db_meta[:cwd],
         model: extract_model(lines) || db_meta[:model_provider],
         summary: user_text || db_meta[:first_user_message],
         title: title,
         git_root: db_meta[:git_origin_url],
         branch: branch,
         agent_version: payload["cli_version"] || db_meta[:cli_version],
         started_at: first_ts || db_meta[:created_at],
         stopped_at: last_ts || db_meta[:updated_at],
         events: events
       }}
    end
  end

  # Creates a minimal session from threads table metadata when JSONL is missing
  defp parse_from_metadata_only(_session_id, nil), do: {:error, :no_data}

  defp parse_from_metadata_only(session_id, db_meta) do
    summary = db_meta[:first_user_message]
    summary = if summary == "", do: nil, else: summary

    {:ok,
     %{
       session_id: session_id,
       cwd: db_meta[:cwd],
       model: db_meta[:model_provider],
       summary: summary,
       title: db_meta[:title] || (summary && String.slice(summary, 0, 120)),
       git_root: db_meta[:git_origin_url],
       branch: db_meta[:git_branch],
       agent_version: db_meta[:cli_version],
       started_at: db_meta[:created_at],
       stopped_at: db_meta[:updated_at],
       events: []
     }}
  end

  # ── SQLite State DB Functions ──

  @doc "Finds the latest state_N.sqlite file in the codex config dir."
  def find_state_db do
    @codex_dir
    |> Path.join("state_*.sqlite")
    |> Path.wildcard()
    |> Enum.sort_by(
      fn path ->
        case Regex.run(~r/state_(\d+)\.sqlite$/, path) do
          [_, n] -> String.to_integer(n)
          _ -> 0
        end
      end,
      :desc
    )
    |> List.first()
  end

  defp discover_from_state_db do
    case find_state_db() do
      nil ->
        %{}

      db_path ->
        try do
          {:ok, conn} = Exqlite.Sqlite3.open(db_path, mode: :readonly)

          try do
            {:ok, stmt} =
              Exqlite.Sqlite3.prepare(conn, "SELECT id, rollout_path FROM threads")

            rows = fetch_all_rows(conn, stmt)
            Exqlite.Sqlite3.release(conn, stmt)

            Map.new(rows, fn [id, rollout_path] -> {id, rollout_path} end)
          after
            Exqlite.Sqlite3.close(conn)
          end
        rescue
          e ->
            Logger.warning("Failed to read codex state DB: #{Exception.message(e)}")
            %{}
        end
    end
  end

  defp read_thread_metadata(session_id) do
    case read_thread_raw(session_id) do
      nil -> nil
      raw -> parse_thread_raw(raw)
    end
  end

  @doc """
  Reads the full raw thread row from the codex state DB.
  Returns a map with string keys matching the threads table columns, or nil.
  """
  def read_thread_raw(session_id) do
    case find_state_db() do
      nil ->
        nil

      db_path ->
        read_thread_raw(session_id, db_path)
    end
  end

  @doc "Reads a thread row from a specific codex state DB path."
  def read_thread_raw(session_id, db_path) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path, mode: :readonly)

    try do
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(conn, "SELECT * FROM threads WHERE id = ?1")

      :ok = Exqlite.Sqlite3.bind(stmt, [session_id])
      {:ok, columns} = Exqlite.Sqlite3.columns(conn, stmt)

      result =
        case Exqlite.Sqlite3.step(conn, stmt) do
          {:row, values} ->
            Enum.zip(columns, values) |> Map.new()

          :done ->
            nil
        end

      Exqlite.Sqlite3.release(conn, stmt)
      result
    after
      Exqlite.Sqlite3.close(conn)
    end
  rescue
    e in [Exqlite.Error, MatchError] ->
      Logger.warning("Failed to read codex thread for #{session_id}: #{Exception.message(e)}")
      nil
  end

  defp parse_thread_raw(raw) when is_map(raw) do
    %{
      cwd: raw["cwd"],
      title: if(raw["title"] == "", do: nil, else: raw["title"]),
      git_sha: raw["git_sha"],
      git_branch: raw["git_branch"],
      git_origin_url: raw["git_origin_url"],
      tokens_used: raw["tokens_used"],
      cli_version: if(raw["cli_version"] == "", do: nil, else: raw["cli_version"]),
      model_provider: raw["model_provider"],
      source: raw["source"],
      sandbox_policy: raw["sandbox_policy"],
      approval_mode: raw["approval_mode"],
      first_user_message:
        if(raw["first_user_message"] == "", do: nil, else: raw["first_user_message"]),
      agent_nickname: raw["agent_nickname"],
      agent_role: raw["agent_role"],
      created_at: parse_epoch_ms(raw["created_at"]),
      updated_at: parse_epoch_ms(raw["updated_at"])
    }
  end

  @doc """
  Builds a codex_thread_meta artifact map from a raw thread row.
  Suitable for storing via SessionArtifact upsert.
  """
  def thread_meta_artifact(raw_thread) when is_map(raw_thread) do
    content = Jason.encode!(raw_thread, pretty: true)
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    %{
      path: "codex_thread.json",
      content: content,
      content_hash: hash,
      artifact_type: :codex_thread_meta,
      size: byte_size(content)
    }
  end

  # ── Delete from Source ──

  @doc """
  Deletes a codex session from the source state DB and removes the JSONL rollout file.
  `session_id` is the raw codex UUID (without the `codex_` prefix).
  """
  def delete_from_source(session_id) do
    results = %{thread_deleted: false, rollout_deleted: false}

    case find_state_db() do
      nil ->
        results

      db_path ->
        # Read rollout_path before deleting the thread
        raw = read_thread_raw(session_id, db_path)
        rollout_path = raw && raw["rollout_path"]

        # Delete thread from state DB
        results =
          try do
            {:ok, conn} = Exqlite.Sqlite3.open(db_path)

            try do
              {:ok, stmt} =
                Exqlite.Sqlite3.prepare(conn, "DELETE FROM threads WHERE id = ?1")

              :ok = Exqlite.Sqlite3.bind(stmt, [session_id])
              :done = Exqlite.Sqlite3.step(conn, stmt)
              changes = Exqlite.Sqlite3.changes(conn)
              Exqlite.Sqlite3.release(conn, stmt)
              %{results | thread_deleted: changes > 0}
            after
              Exqlite.Sqlite3.close(conn)
            end
          rescue
            e ->
              Logger.warning(
                "Failed to delete codex thread #{session_id}: #{Exception.message(e)}"
              )

              results
          end

        # Delete JSONL rollout file
        results =
          if rollout_path && File.exists?(rollout_path) do
            case File.rm(rollout_path) do
              :ok ->
                %{results | rollout_deleted: true}

              {:error, reason} ->
                Logger.warning(
                  "Failed to delete rollout file #{rollout_path}: #{inspect(reason)}"
                )

                results
            end
          else
            results
          end

        results
    end
  end

  # ── Export / Reconstruct ──

  @doc """
  Reconstructs a codex state_N.sqlite database from our stored data.
  Writes to `output_path`. Reads codex sessions from our DB, uses
  codex_thread_meta artifacts for thread rows, and events for JSONL files.

  Options:
    - `:export_jsonl` - also write JSONL rollout files (default: true)
    - `:jsonl_dir` - directory for JSONL files (default: sibling `sessions/` dir)
  """
  def export_state_db(output_path, opts \\ []) do
    export_jsonl = Keyword.get(opts, :export_jsonl, true)

    jsonl_dir =
      Keyword.get(opts, :jsonl_dir, Path.join(Path.dirname(output_path), "sessions"))

    # Load all codex sessions from our DB
    sessions = load_codex_sessions()

    if Enum.empty?(sessions) do
      {:error, :no_codex_sessions}
    else
      File.mkdir_p!(Path.dirname(output_path))
      {:ok, conn} = Exqlite.Sqlite3.open(output_path)

      try do
        create_threads_table(conn)
        exported = %{threads: 0, jsonl_files: 0}

        exported =
          Enum.reduce(sessions, exported, fn session, acc ->
            provider_id = CopilotLv.Sessions.Session.provider_id(session.id)
            thread_row = load_thread_artifact(session.id)

            # Build thread row from artifact or reconstruct from session metadata
            row = build_thread_row(provider_id, session, thread_row)

            # Fix rollout_path to point to the export directory
            row =
              if export_jsonl do
                Map.put(
                  row,
                  "rollout_path",
                  default_rollout_path(jsonl_dir, provider_id, session)
                )
              else
                row
              end

            insert_thread(conn, row)
            acc = %{acc | threads: acc.threads + 1}

            if export_jsonl do
              export_events_to_jsonl(session.id, row["rollout_path"])
              %{acc | jsonl_files: acc.jsonl_files + 1}
            else
              acc
            end
          end)

        {:ok, exported}
      after
        Exqlite.Sqlite3.close(conn)
      end
    end
  end

  defp parse_epoch_ms(nil), do: nil

  defp parse_epoch_ms(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp parse_epoch_ms(_), do: nil

  # ── Export Helpers ──

  defp load_codex_sessions do
    import Ecto.Query

    CopilotLv.Repo.all(
      from(s in "sessions",
        where: s.agent == "codex",
        select: %{
          id: s.id,
          cwd: s.cwd,
          title: s.title,
          summary: s.summary,
          model: s.model,
          branch: s.branch,
          git_root: s.git_root,
          copilot_version: s.copilot_version,
          started_at: s.started_at,
          stopped_at: s.stopped_at,
          event_count: s.event_count
        }
      )
    )
  end

  defp load_thread_artifact(session_id) do
    import Ecto.Query

    case CopilotLv.Repo.one(
           from(a in "session_artifacts",
             where: a.session_id == ^session_id and a.artifact_type == "codex_thread_meta",
             select: a.content
           )
         ) do
      nil -> nil
      content -> Jason.decode!(content)
    end
  rescue
    _ -> nil
  end

  defp build_thread_row(provider_id, session, nil) do
    # No stored artifact — reconstruct from session metadata (best effort)
    started_ms = datetime_to_epoch_ms(session.started_at)
    stopped_ms = datetime_to_epoch_ms(session.stopped_at)

    %{
      "id" => provider_id,
      "rollout_path" => "",
      "created_at" => started_ms || 0,
      "updated_at" => stopped_ms || started_ms || 0,
      "source" => "cli",
      "model_provider" => session.model || "openai",
      "cwd" => session.cwd || "",
      "title" => session.summary || session.title || "",
      "sandbox_policy" => ~s({"type":"read-only"}),
      "approval_mode" => "on-request",
      "tokens_used" => 0,
      "has_user_event" => if(session.event_count > 0, do: 1, else: 0),
      "archived" => 0,
      "archived_at" => nil,
      "git_sha" => nil,
      "git_branch" => session.branch,
      "git_origin_url" => session.git_root,
      "cli_version" => session.copilot_version || "",
      "first_user_message" => session.summary || "",
      "agent_nickname" => nil,
      "agent_role" => nil,
      "memory_mode" => "enabled"
    }
  end

  defp build_thread_row(_provider_id, _session, stored) when is_map(stored) do
    # Use the stored artifact as-is (round-trip faithful)
    stored
  end

  defp datetime_to_epoch_ms(nil), do: nil

  defp datetime_to_epoch_ms(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp datetime_to_epoch_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

  @threads_columns ~w(id rollout_path created_at updated_at source model_provider cwd title
    sandbox_policy approval_mode tokens_used has_user_event archived archived_at
    git_sha git_branch git_origin_url cli_version first_user_message
    agent_nickname agent_role memory_mode)

  defp create_threads_table(conn) do
    Exqlite.Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS threads (
      id TEXT PRIMARY KEY,
      rollout_path TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      source TEXT NOT NULL,
      model_provider TEXT NOT NULL,
      cwd TEXT NOT NULL,
      title TEXT NOT NULL,
      sandbox_policy TEXT NOT NULL,
      approval_mode TEXT NOT NULL,
      tokens_used INTEGER NOT NULL DEFAULT 0,
      has_user_event INTEGER NOT NULL DEFAULT 0,
      archived INTEGER NOT NULL DEFAULT 0,
      archived_at INTEGER,
      git_sha TEXT,
      git_branch TEXT,
      git_origin_url TEXT,
      cli_version TEXT NOT NULL DEFAULT '',
      first_user_message TEXT NOT NULL DEFAULT '',
      agent_nickname TEXT,
      agent_role TEXT,
      memory_mode TEXT NOT NULL DEFAULT 'enabled'
    )
    """)
  end

  defp insert_thread(conn, row) do
    placeholders =
      @threads_columns |> Enum.with_index(1) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

    cols = Enum.join(@threads_columns, ", ")

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        conn,
        "INSERT OR REPLACE INTO threads (#{cols}) VALUES (#{placeholders})"
      )

    values = Enum.map(@threads_columns, fn col -> row[col] end)
    :ok = Exqlite.Sqlite3.bind(stmt, values)
    :done = Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
  end

  defp default_rollout_path(jsonl_dir, provider_id, session) do
    date =
      case session.started_at do
        nil -> "1970-01-01"
        dt when is_binary(dt) -> String.slice(dt, 0, 10)
        %DateTime{} = dt -> Date.to_string(DateTime.to_date(dt))
      end

    [year, month, day] = String.split(date, "-")

    time =
      String.replace(String.slice(to_string(session.started_at || "00-00-00"), 11, 8), ":", "-")

    dir = Path.join([jsonl_dir, year, month, day])
    File.mkdir_p!(dir)
    Path.join(dir, "rollout-#{date}T#{time}-#{provider_id}.jsonl")
  end

  defp export_events_to_jsonl(session_id, rollout_path) do
    import Ecto.Query

    query =
      from(e in "events",
        where: e.session_id == ^session_id,
        order_by: e.sequence,
        select: e.data
      )

    count = CopilotLv.Repo.aggregate(query, :count)

    if count > 0 do
      File.mkdir_p!(Path.dirname(rollout_path))

      file = File.open!(rollout_path, [:write, :utf8])

      try do
        CopilotLv.Repo.transaction(fn ->
          CopilotLv.Repo.stream(query, max_rows: 200)
          |> Enum.each(fn row ->
            data = if is_map(row), do: row.data || row[:data], else: row
            IO.write(file, to_string(data))
            IO.write(file, "\n")
          end)
        end)
      after
        File.close(file)
      end
    end
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

  # ── JSONL File Functions ──

  defp find_jsonl_files(dir) do
    dir
    |> Path.join("**/*.jsonl")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp extract_session_id(path) do
    basename = Path.basename(path, ".jsonl")

    case Regex.run(~r/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/, basename) do
      [_, uuid] -> uuid
      _ -> basename
    end
  end

  defp find_session_meta(lines) do
    Enum.find(lines, &(&1["type"] == "session_meta"))
  end

  defp extract_model(lines) do
    Enum.find_value(lines, fn
      %{"type" => "response_item", "payload" => %{"role" => "assistant"}} = line ->
        get_in(line, ["payload", "model"])

      %{"type" => "session_meta", "payload" => %{"model_provider" => provider}} ->
        provider

      _ ->
        nil
    end)
  end

  defp extract_first_user_message(lines) do
    lines
    |> Enum.filter(fn
      %{"type" => "response_item", "payload" => %{"role" => "user", "content" => content}}
      when is_list(content) ->
        text =
          content
          |> Enum.flat_map(fn
            %{"type" => "input_text", "text" => t} when is_binary(t) -> [t]
            _ -> []
          end)
          |> Enum.join("\n")
          |> String.trim()

        # Skip system-injected messages (AGENTS.md, environment context, permissions)
        text != "" &&
          not String.starts_with?(text, "#") &&
          not String.starts_with?(text, "<")

      _ ->
        false
    end)
    |> Enum.find_value(fn %{"payload" => %{"content" => content}} ->
      content
      |> Enum.flat_map(fn
        %{"type" => "input_text", "text" => t} when is_binary(t) -> [t]
        _ -> []
      end)
      |> Enum.join("\n")
      |> String.trim()
      |> case do
        "" -> nil
        text -> text
      end
    end)
  end

  # The Codex CLI writes two parallel representations for every conversational
  # message: a structured `response_item` (with role/content arrays from the API)
  # and a simplified `event_msg` (with a plain text string for UI display).
  # The response_item variant is richer, so we drop the redundant event_msg
  # subtypes at parse time to avoid storing duplicates.
  @redundant_event_msg_types ~w(user_message agent_message agent_reasoning)
  defp redundant_event_msg?(line) do
    line["type"] == "event_msg" &&
      get_in(line, ["payload", "type"]) in @redundant_event_msg_types
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
