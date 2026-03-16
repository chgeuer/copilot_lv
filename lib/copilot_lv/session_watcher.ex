defmodule CopilotLv.SessionWatcher do
  @moduledoc """
  Watches agent session directories for file changes and performs
  incremental sync to provide near-real-time visibility into active
  CLI sessions across all agents (Copilot, Claude, Codex, Gemini).

  Uses FileSystem (inotify) for immediate detection with a periodic
  poll as fallback. Debounces rapid changes per session.
  """

  use GenServer
  require Logger

  alias Phoenix.PubSub

  @pubsub_topic "sessions:watcher"
  @poll_interval :timer.seconds(10)
  @debounce_ms 2_000

  # ── Public API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "PubSub topic for watcher events."
  def topic, do: @pubsub_topic

  @doc "Returns the list of currently active (recently changed) session IDs."
  def active_sessions do
    GenServer.call(__MODULE__, :active_sessions)
  end

  @doc "Force a sync of all agents now."
  def sync_now do
    GenServer.cast(__MODULE__, :sync_now)
  end

  # ── GenServer Callbacks ──

  @impl true
  def init(_opts) do
    dirs = watch_dirs()

    # Start FileSystem watcher when available; polling remains the fallback.
    watcher_pid = start_file_watcher(dirs)

    # Schedule periodic poll
    timer_ref = Process.send_after(self(), :poll, @poll_interval)

    state = %{
      watcher_pid: watcher_pid,
      timer_ref: timer_ref,
      # %{session_id => %{agent: atom, path: string, last_seen: DateTime, event_count: int}}
      active: %{},
      # %{path => timer_ref} for debouncing
      pending: %{},
      # %{session_id => event_count} last known counts
      known_counts: load_known_counts()
    }

    Logger.info("SessionWatcher started, watching #{length(dirs)} directories")

    {:ok, state}
  end

  @impl true
  def handle_call(:active_sessions, _from, state) do
    active =
      state.active
      |> Enum.map(fn {session_id, info} ->
        %{
          session_id: session_id,
          agent: info.agent,
          path: info.path,
          last_seen: info.last_seen,
          event_count: info.event_count
        }
      end)
      |> Enum.sort_by(& &1.last_seen, {:desc, DateTime})

    {:reply, active, state}
  end

  @impl true
  def handle_cast(:sync_now, state) do
    state = do_full_scan(state)
    {:noreply, state}
  end

  # FileSystem events
  @impl true
  def handle_info({:file_event, _pid, {path, events}}, state) do
    if relevant_file?(path, events) do
      state = debounce_sync(path, state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    Logger.warning("SessionWatcher: FileSystem watcher stopped, restarting...")
    dirs = watch_dirs()
    watcher_pid = start_file_watcher(dirs)
    {:noreply, %{state | watcher_pid: watcher_pid}}
  end

  # Debounce timer fired — sync the file
  def handle_info({:debounce_sync, path}, state) do
    state = %{state | pending: Map.delete(state.pending, path)}
    state = sync_file(path, state)
    {:noreply, state}
  end

  # Periodic poll
  def handle_info(:poll, state) do
    state = do_full_scan(state)
    timer_ref = Process.send_after(self(), :poll, @poll_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals ──

  defp watch_dirs do
    CopilotLv.Agents.all()
    |> Enum.flat_map(& &1.well_known_dirs())
    |> Enum.filter(&File.dir?/1)
  end

  defp start_file_watcher(dirs) do
    cond do
      Code.ensure_loaded?(FileSystem) && function_exported?(FileSystem, :start_link, 1) &&
          function_exported?(FileSystem, :subscribe, 1) ->
        {:ok, watcher_pid} =
          apply(FileSystem, :start_link, [[dirs: dirs, name: :session_watcher_fs]])

        :ok = apply(FileSystem, :subscribe, [:session_watcher_fs])
        watcher_pid

      true ->
        Logger.warning("SessionWatcher: FileSystem dependency unavailable, using polling only")
        nil
    end
  end

  defp relevant_file?(path, events) do
    # Only care about modified/created files that are session files
    has_write = Enum.any?(events, &(&1 in [:modified, :created, :closed]))

    has_write &&
      (String.ends_with?(path, ".jsonl") ||
         String.ends_with?(path, ".json") ||
         String.ends_with?(path, "workspace.yaml"))
  end

  defp debounce_sync(path, state) do
    # Cancel existing debounce timer for this path
    case Map.get(state.pending, path) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end

    ref = Process.send_after(self(), {:debounce_sync, path}, @debounce_ms)
    %{state | pending: Map.put(state.pending, path, ref)}
  end

  defp sync_file(path, state) do
    case identify_session(path) do
      {:ok, agent_type, session_id, session_path} ->
        do_sync_session(agent_type, session_id, session_path, state)

      :ignore ->
        state
    end
  end

  defp identify_session(path) do
    cond do
      # Copilot: ~/.copilot/session-state/{uuid}/events.jsonl
      #      or ~/.local/state/.copilot/session-state/{uuid}/events.jsonl
      String.contains?(path, ".copilot/session-state") &&
          String.ends_with?(path, "events.jsonl") ->
        session_id = path |> Path.dirname() |> Path.basename()
        {:ok, :copilot, session_id, Path.dirname(path)}

      # Claude: ~/.claude/projects/{encoded-path}/{session-id}.jsonl
      String.contains?(path, ".claude/projects") &&
          String.ends_with?(path, ".jsonl") ->
        session_id = Path.basename(path, ".jsonl")
        {:ok, :claude, session_id, path}

      # Codex: ~/.codex/sessions/{y}/{m}/{d}/rollout-*-{uuid}.jsonl
      String.contains?(path, ".codex/sessions") &&
          String.ends_with?(path, ".jsonl") ->
        session_id = extract_codex_id(path)
        {:ok, :codex, session_id, path}

      # Gemini: ~/.gemini/tmp/{hash}/chats/session-*.json
      String.contains?(path, ".gemini") &&
        String.contains?(path, "/chats/session-") &&
          String.ends_with?(path, ".json") ->
        session_id = extract_gemini_id(path)
        {:ok, :gemini, session_id, path}

      true ->
        :ignore
    end
  end

  defp extract_codex_id(path) do
    basename = Path.basename(path, ".jsonl")

    case Regex.run(~r/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/, basename) do
      [_, uuid] -> uuid
      _ -> basename
    end
  end

  defp extract_gemini_id(path) do
    basename = Path.basename(path, ".json")

    case Regex.run(~r/session-[\d\-T]+-([0-9a-f]+)$/, basename) do
      [_, short_id] -> short_id
      _ -> basename
    end
  end

  defp do_sync_session(agent_type, session_id, session_path, state) do
    prefixed_id = CopilotLv.Sessions.Session.prefixed_id(agent_type, session_id)

    case CopilotLv.Agents.parse_session(agent_type, session_path) do
      {:ok, parsed} ->
        source_count = length(parsed.events)
        known_count = Map.get(state.known_counts, prefixed_id, 0)

        if source_count > known_count do
          result = upsert_session(agent_type, session_id, session_path, parsed)

          new_active =
            Map.put(state.active, prefixed_id, %{
              agent: agent_type,
              path: session_path,
              last_seen: DateTime.utc_now(),
              event_count: source_count
            })

          new_known = Map.put(state.known_counts, prefixed_id, source_count)

          broadcast_update(prefixed_id, agent_type, source_count, known_count, result)

          %{state | active: new_active, known_counts: new_known}
        else
          state
        end

      {:error, _} ->
        state
    end
  rescue
    e ->
      Logger.warning(
        "SessionWatcher sync error for #{agent_type}/#{session_id}: #{Exception.message(e)}"
      )

      state
  end

  defp upsert_session(agent_type, session_id, session_path, parsed) do
    alias CopilotLv.Sessions.Session
    prefixed_id = Session.prefixed_id(agent_type, session_id)
    hostname = local_hostname()

    case Ash.get(Session, prefixed_id) do
      {:ok, existing} ->
        # Incremental event append
        import_events(existing.id, parsed.events)

        existing
        |> Ash.Changeset.for_update(:update_import, %{
          summary: parsed.summary || existing.summary,
          title: parsed.title || existing.title,
          event_count: max(length(parsed.events), existing.event_count || 0),
          imported_at: DateTime.utc_now(),
          hostname: hostname,
          agent: agent_type,
          branch: parsed.branch || existing.branch,
          git_root: parsed.git_root || existing.git_root,
          model: parsed.model || existing.model,
          stopped_at: parsed.stopped_at || existing.stopped_at
        })
        |> Ash.update!()

        :updated

      {:error, _} ->
        # New session
        config_dir =
          case agent_type do
            :copilot ->
              if is_binary(session_path) &&
                   String.contains?(session_path, ".copilot/session-state") do
                # session_path is either a dir or a .jsonl file inside session-state
                parent =
                  if File.dir?(session_path),
                    do: Path.dirname(session_path),
                    else: Path.dirname(session_path)

                parent
              else
                Path.expand("~/.copilot/session-state")
              end

            :claude ->
              Path.expand("~/.claude/projects")

            :codex ->
              Path.expand("~/.codex/sessions")

            :gemini ->
              Path.expand("~/.gemini/tmp")
          end

        session_attrs = %{
          id: prefixed_id,
          cwd: parsed.cwd || "unknown",
          model: parsed.model,
          summary: parsed.summary,
          title: parsed.title,
          git_root: parsed.git_root,
          branch: parsed.branch,
          copilot_version: parsed.agent_version,
          source: :imported,
          status: :stopped,
          started_at: parsed.started_at,
          stopped_at: parsed.stopped_at,
          imported_at: DateTime.utc_now(),
          event_count: length(parsed.events),
          hostname: hostname,
          agent: agent_type,
          config_dir: config_dir
        }

        Session
        |> Ash.Changeset.for_create(:import, session_attrs)
        |> Ash.create!()

        import_events(prefixed_id, parsed.events)
        :imported
    end
  end

  defp import_events(session_id, events) do
    repo = CopilotLv.Repo

    events
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      entries =
        Enum.map(chunk, fn event ->
          %{
            id: Ash.UUIDv7.generate(),
            event_type: event.type,
            event_id: nil,
            parent_event_id: nil,
            data: Jason.encode!(event.data || %{}),
            timestamp: event.timestamp,
            sequence: event.sequence,
            session_id: session_id
          }
        end)

      repo.insert_all("events", entries,
        log: false,
        on_conflict: :nothing,
        conflict_target: [:session_id, :sequence]
      )
    end)
  end

  defp do_full_scan(state) do
    # Only check recently modified files (since last poll + buffer)
    cutoff = System.os_time(:second) - div(@poll_interval, 1000) - 5

    CopilotLv.Agents.all()
    |> Enum.flat_map(fn mod ->
      mod.well_known_dirs()
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(fn dir -> find_recent_files(dir, cutoff, mod.agent_type()) end)
    end)
    |> Enum.reduce(state, fn {agent_type, session_id, path}, state ->
      do_sync_session(agent_type, session_id, path, state)
    end)
  end

  defp find_recent_files(dir, cutoff, agent_type) do
    case agent_type do
      :codex ->
        Path.join(dir, "**/*.jsonl")
        |> Path.wildcard()
        |> filter_by_mtime(cutoff)
        |> Enum.map(fn path ->
          {:codex, extract_codex_id(path), path}
        end)

      :claude ->
        Path.join(dir, "**/*.jsonl")
        |> Path.wildcard()
        |> Enum.reject(&String.contains?(&1, "sessions-index"))
        |> filter_by_mtime(cutoff)
        |> Enum.map(fn path ->
          {:claude, Path.basename(path, ".jsonl"), path}
        end)

      :copilot ->
        Path.join(dir, "*/events.jsonl")
        |> Path.wildcard()
        |> filter_by_mtime(cutoff)
        |> Enum.map(fn path ->
          session_id = path |> Path.dirname() |> Path.basename()
          {:copilot, session_id, Path.dirname(path)}
        end)

      :gemini ->
        Path.join(dir, "**/chats/session-*.json")
        |> Path.wildcard()
        |> filter_by_mtime(cutoff)
        |> Enum.map(fn path ->
          {:gemini, extract_gemini_id(path), path}
        end)
    end
  rescue
    _ -> []
  end

  defp filter_by_mtime(paths, cutoff) do
    Enum.filter(paths, fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} -> mtime >= cutoff
        _ -> false
      end
    end)
  end

  defp load_known_counts do
    CopilotLv.Sessions.Session
    |> Ash.read!()
    |> Map.new(&{&1.id, &1.event_count || 0})
  rescue
    _ -> %{}
  end

  defp broadcast_update(session_id, agent_type, new_count, old_count, result) do
    PubSub.broadcast(CopilotLv.PubSub, @pubsub_topic, {
      :session_updated,
      %{
        session_id: session_id,
        agent: agent_type,
        event_count: new_count,
        new_events: new_count - old_count,
        result: result,
        timestamp: DateTime.utc_now()
      }
    })
  end

  defp local_hostname do
    case File.read("/etc/hostname") do
      {:ok, name} -> String.trim(name)
      _ -> "localhost"
    end
  end
end
