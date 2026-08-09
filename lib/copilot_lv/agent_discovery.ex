defmodule CopilotLv.AgentDiscovery do
  @moduledoc """
  Unified session discovery and import for all agents, locally and via SSH.
  """

  require Logger

  alias CopilotLv.SessionStoreImpl

  @doc """
  Discover sessions on the local machine.
  Returns `[{agent_type, session_id, path, config_dir}]`.
  """
  def discover_local(agent \\ :all) do
    CopilotLv.Agents.discover_local(agent)
  end

  @doc """
  Discover sessions on a remote host via SSH.
  Returns `[{agent_type, session_id, remote_path, config_dir}]`.
  """
  def discover_remote(hostname, agent \\ :all, extra_dirs \\ []) do
    modules =
      if agent == :all, do: CopilotLv.Agents.all(), else: [CopilotLv.Agents.for_type(agent)]

    modules = Enum.reject(modules, &is_nil/1)

    Enum.flat_map(modules, fn mod ->
      Code.ensure_loaded!(mod)

      dirs =
        if function_exported?(mod, :remote_well_known_dirs, 0) do
          mod.remote_well_known_dirs()
        else
          mod.well_known_dirs()
        end

      dirs = dirs ++ extra_dirs

      Enum.flat_map(dirs, fn dir ->
        case ssh_list_files(hostname, dir, mod.agent_type()) do
          {:ok, files} ->
            Enum.map(files, fn {sid, remote_path} ->
              {mod.agent_type(), sid, remote_path, dir}
            end)

          {:error, reason} ->
            Logger.warning("SSH discovery failed for #{hostname}:#{dir}: #{inspect(reason)}")
            []
        end
      end)
    end)
  end

  @doc """
  Import all sessions for the given agent(s) from the local machine.
  """
  def import_local(agent \\ :all, opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)
    dry_run = Keyword.get(opts, :dry_run, false)
    hostname = local_hostname()

    discovered = discover_local(agent)

    if verbose do
      Logger.info("Discovered #{length(discovered)} sessions locally")
    end

    existing = load_existing_sessions()

    stats = initial_stats()

    Enum.reduce(discovered, stats, fn {agent_type, session_id, path, config_dir}, stats ->
      prefixed = CopilotLv.Sessions.Session.prefixed_id(agent_type, session_id)

      case Map.get(existing, prefixed) do
        nil ->
          # New session — import
          import_new(agent_type, session_id, path, config_dir, hostname, dry_run, verbose, stats)

        %{source: :live} ->
          # Live session — skip
          %{stats | skipped: stats.skipped + 1}

        existing_session ->
          # Existing imported session — check if repair needed
          maybe_repair(
            existing_session,
            agent_type,
            path,
            config_dir,
            hostname,
            dry_run,
            verbose,
            stats
          )
      end
    end)
  end

  @doc """
  Import sessions from a remote host via SSH + scp.
  """
  def import_remote(hostname, agent \\ :all, opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)
    dry_run = Keyword.get(opts, :dry_run, false)
    extra_dirs = Keyword.get(opts, :dirs, [])

    discovered = discover_remote(hostname, agent, extra_dirs)

    if verbose do
      Logger.info("Discovered #{length(discovered)} sessions on #{hostname}")
    end

    existing = load_existing_sessions()
    force = Keyword.get(opts, :force, false)

    stats = initial_stats()

    Enum.reduce(discovered, stats, fn {agent_type, session_id, remote_path, config_dir}, stats ->
      prefixed = CopilotLv.Sessions.Session.prefixed_id(agent_type, session_id)

      case Map.get(existing, prefixed) do
        nil ->
          if dry_run do
            if verbose,
              do: Logger.info("Would import #{agent_type}/#{session_id} from #{hostname}")

            %{stats | imported: stats.imported + 1}
          else
            case scp_and_import(hostname, remote_path, agent_type, config_dir) do
              {:ok, _} ->
                if verbose,
                  do: Logger.info("Imported #{agent_type}/#{session_id} from #{hostname}")

                %{stats | imported: stats.imported + 1}

              {:error, reason} ->
                Logger.warning("Import failed for #{session_id}: #{inspect(reason)}")
                %{stats | errors: stats.errors + 1}
            end
          end

        %{source: :live} ->
          %{stats | skipped: stats.skipped + 1}

        existing_session when force ->
          if dry_run do
            if verbose,
              do: Logger.info("Would re-import #{agent_type}/#{session_id} from #{hostname}")

            %{stats | repaired: stats.repaired + 1}
          else
            delete_session_data(existing_session)

            case scp_and_import(hostname, remote_path, agent_type, config_dir) do
              {:ok, _} ->
                if verbose,
                  do: Logger.info("Re-imported #{agent_type}/#{session_id} from #{hostname}")

                %{stats | repaired: stats.repaired + 1}

              {:error, reason} ->
                Logger.warning("Re-import failed for #{session_id}: #{inspect(reason)}")
                %{stats | errors: stats.errors + 1}
            end
          end

        _existing_session ->
          %{stats | skipped: stats.skipped + 1}
      end
    end)
  end

  # ── Internal ──

  defp delete_session_data(session) do
    SessionStoreImpl.delete_session(session.id)
  end

  defp import_new(agent_type, session_id, path, config_dir, hostname, dry_run, verbose, stats) do
    case CopilotLv.Agents.parse_session(agent_type, path) do
      {:ok, parsed} ->
        stats = collect_artifact_stats(stats, agent_type, nil, session_id, parsed.cwd, path)

        if dry_run do
          if verbose, do: Logger.info("Would import #{agent_type}/#{session_id}")
          %{stats | imported: stats.imported + 1}
        else
          case do_import(parsed, agent_type, hostname, config_dir, path) do
            {:ok, _} ->
              if verbose, do: Logger.info("Imported #{agent_type}/#{session_id}")
              %{stats | imported: stats.imported + 1}

            {:error, reason} ->
              Logger.warning("Import failed for #{session_id}: #{inspect(reason)}")
              %{stats | errors: stats.errors + 1}
          end
        end

      {:error, _reason} ->
        %{stats | skipped: stats.skipped + 1}
    end
  end

  defp maybe_repair(
         existing_session,
         agent_type,
         path,
         config_dir,
         hostname,
         dry_run,
         verbose,
         stats
       ) do
    case CopilotLv.Agents.parse_session(agent_type, path) do
      {:ok, parsed} ->
        stats =
          collect_artifact_stats(
            stats,
            agent_type,
            existing_session.id,
            CopilotLv.Sessions.Session.provider_id(existing_session.id),
            parsed.cwd || existing_session.cwd,
            path
          )

        source_count = length(parsed.events)
        db_count = SessionStoreImpl.event_count(existing_session.id)
        has_new_events = source_count > db_count

        has_metadata_changes =
          (parsed.summary || parsed.title) != nil &&
            ((parsed.summary != existing_session.summary && parsed.summary != nil) ||
               (parsed.title != existing_session.title && parsed.title != nil) ||
               (parsed.branch != existing_session.branch && parsed.branch != nil) ||
               (parsed.git_root != existing_session.git_root && parsed.git_root != nil) ||
               (parsed.model != existing_session.model && parsed.model != nil))

        if has_new_events || has_metadata_changes do
          if dry_run do
            if verbose do
              reason =
                cond do
                  has_new_events -> "(#{db_count}→#{source_count} events)"
                  has_metadata_changes -> "(metadata update)"
                  true -> ""
                end

              Logger.info("Would repair #{agent_type}/#{existing_session.id} #{reason}")
            end

            %{stats | repaired: stats.repaired + 1}
          else
            repair_session(existing_session, parsed, agent_type, config_dir, hostname, path)

            if verbose do
              reason =
                cond do
                  has_new_events -> "(#{db_count}→#{source_count} events)"
                  has_metadata_changes -> "(metadata update)"
                  true -> ""
                end

              Logger.info("Repaired #{agent_type}/#{existing_session.id} #{reason}")
            end

            %{stats | repaired: stats.repaired + 1}
          end
        else
          # Artifacts can change without any new conversation events.
          unless dry_run do
            provider_id = CopilotLv.Sessions.Session.provider_id(existing_session.id)
            store_codex_thread_meta(agent_type, provider_id, existing_session.id)
            sync_agent_artifacts(agent_type, existing_session.id, existing_session.cwd, path)
          end

          %{stats | skipped: stats.skipped + 1}
        end

      {:error, _} ->
        %{stats | skipped: stats.skipped + 1}
    end
  end

  defp repair_session(
         %JidoSessions.Session{} = existing_session,
         parsed,
         agent_type,
         _config_dir,
         hostname,
         source_path
       ) do
    # Incremental event append (on_conflict: :nothing handles idempotency)
    import_events(existing_session.id, parsed.events)

    # Store/update codex thread metadata artifact
    provider_id = CopilotLv.Sessions.Session.provider_id(existing_session.id)
    store_codex_thread_meta(agent_type, provider_id, existing_session.id)

    # Import files from agent session directory (tool-results, etc.)
    sync_agent_artifacts(
      agent_type,
      existing_session.id,
      parsed.cwd || existing_session.cwd,
      source_path
    )

    # Update session metadata via SessionStoreImpl
    updated_session = %JidoSessions.Session{
      existing_session
      | agent: agent_type,
        status: :stopped,
        summary: parsed.summary || existing_session.summary,
        title: parsed.title || existing_session.title,
        git_root: parsed.git_root || existing_session.git_root,
        branch: parsed.branch || existing_session.branch,
        model: parsed.model || existing_session.model,
        stopped_at: parsed.stopped_at || existing_session.stopped_at,
        hostname: hostname
    }

    SessionStoreImpl.upsert_session(updated_session)
  end

  defp do_import(parsed, agent_type, hostname, _config_dir, source_path) do
    id = CopilotLv.Sessions.Session.prefixed_id(agent_type, parsed.session_id)

    jido_session = %JidoSessions.Session{
      id: id,
      agent: agent_type,
      source: :imported,
      status: :stopped,
      cwd: parsed.cwd || "unknown",
      model: parsed.model,
      summary: parsed.summary,
      title: parsed.title,
      git_root: parsed.git_root,
      branch: parsed.branch,
      agent_version: parsed.agent_version,
      started_at: parsed.started_at,
      stopped_at: parsed.stopped_at,
      hostname: hostname
    }

    case SessionStoreImpl.upsert_session(jido_session) do
      {:ok, session} ->
        import_events(session.id, parsed.events)
        store_codex_thread_meta(agent_type, parsed.session_id, session.id)

        case sync_agent_artifacts(agent_type, session.id, session.cwd, source_path) do
          :ok -> {:ok, session}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_events(session_id, events) do
    entries =
      Enum.map(events, fn event ->
        data = event.data || %{}

        %{
          type: event.type,
          data: data,
          raw_data: event[:raw_data] || data,
          timestamp: event.timestamp,
          sequence: event.sequence,
          event_id: data["id"],
          parent_event_id: data["parentId"]
        }
      end)

    SessionStoreImpl.insert_events(session_id, entries)
  end

  defp load_existing_sessions do
    SessionStoreImpl.list_sessions([])
    |> Map.new(&{&1.id, &1})
  end

  defp store_codex_thread_meta(:codex, provider_id, session_id) do
    case CopilotLv.Agents.Codex.read_thread_raw(provider_id) do
      nil ->
        :ok

      raw ->
        art_map = CopilotLv.Agents.Codex.thread_meta_artifact(raw)

        artifact = %JidoSessions.Artifact{
          path: art_map.path,
          artifact_type: art_map.artifact_type,
          content: art_map.content,
          content_hash: art_map.content_hash,
          size: art_map.size
        }

        SessionStoreImpl.upsert_artifacts(session_id, [artifact])
        :ok
    end
  rescue
    _ -> :ok
  end

  defp store_codex_thread_meta(_agent_type, _provider_id, _session_id), do: :ok

  defp sync_agent_artifacts(_agent_type, _session_id, _project_key, nil), do: :ok

  defp sync_agent_artifacts(agent_type, session_id, project_key, source_path) do
    provider_id = CopilotLv.Sessions.Session.provider_id(session_id)
    report = CopilotLv.ArtifactScanner.scan_session(agent_type, provider_id, source_path)

    session_result =
      SessionStoreImpl.reconcile_artifacts(session_id, agent_type, report.artifacts)

    project_result =
      if is_binary(project_key) and project_key != "" and project_key != "unknown" do
        project_report =
          CopilotLv.ArtifactScanner.scan_project_documents(agent_type, project_key, source_path)

        SessionStoreImpl.reconcile_project_documents(
          agent_type,
          project_key,
          project_report.artifacts
        )
      else
        %{stored: 0, removed: 0}
      end

    case {session_result, project_result} do
      {%{}, %{}} ->
        :ok

      {{:error, reason}, _} ->
        Logger.warning("Artifact reconciliation failed for #{session_id}: #{inspect(reason)}")
        {:error, reason}

      {_, {:error, reason}} ->
        Logger.warning(
          "Project document reconciliation failed for #{project_key}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("Artifact scan failed for #{session_id}: #{Exception.message(error)}")
      {:error, error}
  end

  defp collect_artifact_stats(
         stats,
         agent_type,
         db_session_id,
         provider_id,
         project_key,
         source_path
       ) do
    report = CopilotLv.ArtifactScanner.scan_session(agent_type, provider_id, source_path)

    diff =
      if db_session_id do
        SessionStoreImpl.artifact_diff(db_session_id, agent_type, report.artifacts)
      else
        %{added: length(report.artifacts), updated: 0, unchanged: 0, removed: 0}
      end

    project_report =
      if is_binary(project_key) and project_key not in ["", "unknown"] do
        CopilotLv.ArtifactScanner.scan_project_documents(agent_type, project_key, source_path)
      else
        %{artifacts: [], excluded: %{}}
      end

    stats
    |> Map.update!(:artifact_candidates, &(&1 + length(report.artifacts)))
    |> Map.update!(:artifact_added, &(&1 + diff.added))
    |> Map.update!(:artifact_updated, &(&1 + diff.updated))
    |> Map.update!(:artifact_removed, &(&1 + diff.removed))
    |> Map.update!(:artifact_truncated, fn count ->
      count + Enum.count(report.artifacts, & &1.truncated)
    end)
    |> Map.update!(:artifact_excluded, fn count ->
      count + Enum.sum(Map.values(report.excluded))
    end)
    |> Map.update!(:project_documents, &(&1 + length(project_report.artifacts)))
  end

  defp initial_stats do
    %{
      imported: 0,
      repaired: 0,
      skipped: 0,
      errors: 0,
      artifact_candidates: 0,
      artifact_added: 0,
      artifact_updated: 0,
      artifact_removed: 0,
      artifact_truncated: 0,
      artifact_excluded: 0,
      project_documents: 0
    }
  end

  defp ssh_list_files(hostname, dir, agent_type) do
    cmd =
      case agent_type do
        :copilot ->
          "ls -1 #{dir}/ 2>/dev/null | while read d; do echo #{dir}/$d; done | head -500"

        :claude ->
          "find #{dir}/ -maxdepth 2 -name '*.jsonl' -not -name 'sessions-index.json' 2>/dev/null | head -500"

        :codex ->
          "find #{dir}/ -name '*.jsonl' 2>/dev/null | head -500"

        :gemini ->
          "find #{dir}/ -path '*/chats/session-*.json' 2>/dev/null | head -500"

        :pi ->
          "find #{dir}/ -maxdepth 2 -name '*.jsonl' 2>/dev/null | head -500"
      end

    case System.cmd("ssh", [hostname, cmd], stderr_to_stdout: true) do
      {output, 0} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            path = String.trim(line)
            sid = extract_remote_session_id(path, agent_type)
            {sid, path}
          end)
          |> Enum.reject(fn {sid, _} -> sid == "" end)

        {:ok, files}

      {error, _} ->
        {:error, error}
    end
  end

  defp extract_remote_session_id(path, :copilot) do
    Path.basename(path)
  end

  defp extract_remote_session_id(path, :claude) do
    path |> Path.basename() |> String.trim_trailing(".jsonl")
  end

  defp extract_remote_session_id(path, :codex) do
    basename = Path.basename(path, ".jsonl")

    case Regex.run(~r/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/, basename) do
      [_, uuid] -> uuid
      _ -> basename
    end
  end

  defp extract_remote_session_id(path, :gemini) do
    basename = Path.basename(path, ".json")

    case Regex.run(~r/session-[\d\-T]+-([0-9a-f]+)$/, basename) do
      [_, short_id] -> short_id
      _ -> basename
    end
  end

  defp extract_remote_session_id(path, :pi) do
    basename = Path.basename(path, ".jsonl")

    case String.split(basename, "_", parts: 2) do
      [_timestamp, uuid] -> uuid
      [single] -> single
    end
  end

  defp scp_and_import(hostname, remote_path, agent_type, config_dir) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "copilot_lv_import_#{:erlang.system_time(:millisecond)}")

    File.mkdir_p!(tmp_dir)

    local_path =
      case agent_type do
        :gemini ->
          chats_dir = Path.join(tmp_dir, "chats")
          File.mkdir_p!(chats_dir)
          Path.join(chats_dir, Path.basename(remote_path))

        _ ->
          Path.join(tmp_dir, Path.basename(remote_path))
      end

    try do
      # For copilot, scp the whole directory; for others, just the file
      {scp_src, scp_opts} =
        if agent_type == :copilot do
          {"#{hostname}:#{remote_path}", ["-r"]}
        else
          {"#{hostname}:#{remote_path}", []}
        end

      case System.cmd("scp", scp_opts ++ [scp_src, local_path], stderr_to_stdout: true) do
        {_, 0} ->
          stage_remote_sidecars(hostname, remote_path, local_path, agent_type, tmp_dir)

          case CopilotLv.Agents.parse_session(agent_type, local_path) do
            {:ok, parsed} ->
              # For Claude: fix cwd from remote path if local parse got temp dir
              parsed = maybe_fix_cwd(parsed, agent_type, remote_path)
              do_import(parsed, agent_type, hostname, config_dir, local_path)

            error ->
              error
          end

        {error, _} ->
          {:error, "scp failed: #{error}"}
      end
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp stage_remote_sidecars(hostname, remote_path, _local_path, :claude, tmp_dir) do
    session_id = remote_path |> Path.basename() |> String.trim_trailing(".jsonl")
    remote_project_dir = Path.dirname(remote_path)

    scp_optional(
      hostname,
      Path.join(remote_project_dir, session_id),
      Path.join(tmp_dir, session_id)
    )

    scp_optional(
      hostname,
      Path.join(remote_project_dir, "memory"),
      Path.join(tmp_dir, "memory")
    )
  end

  defp stage_remote_sidecars(hostname, remote_path, _local_path, :gemini, tmp_dir) do
    remote_project_dir = remote_path |> Path.dirname() |> Path.dirname()
    short_id = extract_remote_session_id(remote_path, :gemini)

    command =
      "find #{remote_project_dir}/tool-outputs -maxdepth 1 -type d -name 'session-*#{short_id}*' -print -quit 2>/dev/null"

    case System.cmd("ssh", [hostname, command], stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "" ->
            :ok

          remote_sidecar ->
            local_tool_outputs = Path.join(tmp_dir, "tool-outputs")
            File.mkdir_p!(local_tool_outputs)

            scp_optional(
              hostname,
              remote_sidecar,
              Path.join(local_tool_outputs, Path.basename(remote_sidecar))
            )
        end

      _ ->
        :ok
    end
  end

  defp stage_remote_sidecars(_hostname, _remote_path, _local_path, _agent_type, _tmp_dir),
    do: :ok

  defp scp_optional(hostname, remote_path, local_path) do
    case System.cmd("scp", ["-r", "#{hostname}:#{remote_path}", local_path],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      _ -> :ok
    end
  end

  defp maybe_fix_cwd(parsed, :claude, remote_path) do
    # Extract cwd from the remote project directory name
    # e.g., /home/user/.claude/projects/-home-chgeuer-src-work/session.jsonl
    project_dir = remote_path |> Path.dirname() |> Path.basename()
    remote_cwd = JidoSessions.AgentParsers.Claude.decode_project_dir(project_dir)

    # Also try extracting from event data
    event_cwd =
      Enum.find_value(parsed.events, fn event ->
        data = event.data

        cond do
          is_map(data) && is_binary(data["cwd"]) -> data["cwd"]
          true -> nil
        end
      end)

    cwd = event_cwd || remote_cwd
    %{parsed | cwd: cwd}
  end

  defp maybe_fix_cwd(parsed, :codex, _remote_path) do
    # Codex has cwd in session_meta, try extracting from events
    event_cwd =
      Enum.find_value(parsed.events, fn event ->
        data = event.data
        get_in(data, ["payload", "cwd"])
      end)

    if event_cwd, do: %{parsed | cwd: event_cwd}, else: parsed
  end

  defp maybe_fix_cwd(parsed, _agent_type, _remote_path), do: parsed

  defp local_hostname do
    case File.read("/etc/hostname") do
      {:ok, name} -> String.trim(name)
      _ -> "localhost"
    end
  end
end
