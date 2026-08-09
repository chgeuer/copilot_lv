defmodule CopilotLv.SessionStoreImpl do
  @moduledoc """
  SessionStore implementation using Ash resources and AshSqlite.

  Wraps the existing CopilotLv.Sessions.* Ash resources to implement
  the JidoSessions.SessionStore behaviour.
  """

  @behaviour JidoSessions.SessionStore

  alias CopilotLv.Repo

  alias CopilotLv.Sessions.{
    Session,
    Event,
    Checkpoint,
    SessionArtifact,
    ProjectDocument,
    SessionTodo,
    UsageEntry
  }

  # ── Sessions ──

  @impl true
  def upsert_session(session) do
    attrs = session_to_attrs(session)
    prefixed_id = attrs.id

    result =
      case Ash.get(Session, prefixed_id) do
        {:ok, existing} ->
          existing
          |> Ash.Changeset.for_update(
            :update_import,
            Map.drop(attrs, [:id, :cwd, :agent, :config_dir])
          )
          |> Ash.update()
          |> wrap_session()

        {:error, _} ->
          Session
          |> Ash.Changeset.for_create(:import, attrs)
          |> Ash.create()
          |> wrap_session()
      end

    if match?({:ok, _}, result) do
      CopilotLv.ModelCatalog.observe_model(attrs.agent, attrs.model)
    end

    result
  end

  @impl true
  def get_session(id) do
    case Ash.get(Session, id) do
      {:ok, s} -> {:ok, db_to_session(s)}
      {:error, _} -> {:error, :not_found}
    end
  end

  @impl true
  def list_sessions(filters \\ []) do
    Session
    |> Ash.Query.for_read(:list_all)
    |> Ash.read!()
    |> Enum.map(&db_to_session/1)
    |> apply_filters(filters)
  end

  @impl true
  def delete_session(id) do
    case Ash.get(Session, id) do
      {:ok, session} ->
        for table <- [
              "events",
              "usage_entries",
              "checkpoints",
              "session_todos",
              "session_artifacts"
            ] do
          Repo.query!("DELETE FROM #{table} WHERE session_id = ?1", [id])
        end

        Ash.destroy!(session)
        CopilotLv.ModelCatalog.invalidate()
        :ok

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @impl true
  def session_exists?(id) do
    case Ash.get(Session, id) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # ── Events ──

  @impl true
  def insert_events(session_id, events) do
    entries =
      Enum.map(events, fn event ->
        %{
          id: Ash.UUIDv7.generate(),
          event_type: event.type || "unknown",
          event_id: event[:event_id] || event[:id],
          parent_event_id: event[:parent_event_id] || event[:parentId],
          data: encode_data(event.data || %{}),
          raw_data: encode_data(event[:raw_data]),
          timestamp: event.timestamp,
          sequence: event.sequence || 0,
          session_id: session_id
        }
      end)

    count =
      entries
      |> Enum.chunk_every(500)
      |> Enum.reduce(0, fn chunk, acc ->
        {inserted, _} =
          Repo.insert_all("events", chunk,
            log: false,
            on_conflict: :nothing,
            conflict_target: [:session_id, :sequence]
          )

        acc + inserted
      end)

    if count > 0 do
      refresh_event_count(session_id)

      case CopilotLv.Sessions.Session.agent_from_id(session_id) do
        nil -> :ok
        agent -> CopilotLv.ModelCatalog.observe_event_models(agent, events)
      end
    end

    {:ok, count}
  end

  @impl true
  def get_events(session_id) do
    Event
    |> Ash.Query.for_read(:for_session, %{session_id: session_id})
    |> Ash.read!()
    |> Enum.map(fn e ->
      %{
        id: e.id,
        type: e.event_type,
        data: e.data || %{},
        timestamp: e.timestamp,
        sequence: e.sequence
      }
    end)
  end

  @impl true
  def event_count(session_id) do
    import Ecto.Query, only: [from: 2]

    Repo.one(from(e in "events", where: e.session_id == ^session_id, select: count()))
  end

  @doc "Updates the session's event_count field from the actual events table count."
  def refresh_event_count(session_id) do
    actual = event_count(session_id)

    case Ash.get(Session, session_id) do
      {:ok, session} ->
        session
        |> Ash.Changeset.for_update(:update_import, %{event_count: actual})
        |> Ash.update()

      _ ->
        :ok
    end
  end

  # ── Artifacts ──

  @impl true
  def upsert_artifacts(session_id, artifacts) do
    Enum.reduce_while(artifacts, :ok, fn art, :ok ->
      content = artifact_value(art, :content, "")

      changeset =
        SessionArtifact
        |> Ash.Changeset.for_create(:upsert, %{
          session_id: session_id,
          path: artifact_value(art, :path),
          content: content,
          content_hash: artifact_value(art, :content_hash) || content_hash(content),
          size: artifact_value(art, :size, byte_size(content)),
          artifact_type: artifact_value(art, :artifact_type, :file),
          category: artifact_value(art, :category),
          source_agent: artifact_value(art, :source_agent),
          source_path: artifact_value(art, :source_path),
          mime_type: artifact_value(art, :mime_type),
          modified_at: artifact_value(art, :modified_at),
          original_size: artifact_value(art, :original_size),
          stored_size: artifact_value(art, :stored_size),
          truncated: artifact_value(art, :truncated, false),
          managed: artifact_value(art, :managed, false)
        })

      case Ash.create(changeset) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Upserts a scanner manifest and removes managed artifacts no longer present at the source."
  def reconcile_artifacts(session_id, agent, artifacts) do
    with :ok <- upsert_artifacts(session_id, artifacts) do
      retained_paths = MapSet.new(artifacts, &artifact_value(&1, :path))

      removable =
        SessionArtifact
        |> Ash.Query.for_read(:for_session, %{session_id: session_id})
        |> Ash.read!()
        |> Enum.filter(fn artifact ->
          (artifact.managed and artifact.source_agent == agent) or
            (is_nil(artifact.source_agent) and
               artifact.artifact_type in [:file, :plan, :workspace])
        end)
        |> Enum.reject(&MapSet.member?(retained_paths, &1.path))

      Enum.each(removable, &Ash.destroy!/1)
      %{stored: length(artifacts), removed: length(removable)}
    end
  end

  @doc "Compares a scanner manifest with managed artifacts currently stored for a session."
  def artifact_diff(session_id, agent, artifacts) do
    existing =
      SessionArtifact
      |> Ash.Query.for_read(:for_session, %{session_id: session_id})
      |> Ash.read!()
      |> Enum.filter(fn artifact ->
        (artifact.managed and artifact.source_agent == agent) or
          (is_nil(artifact.source_agent) and
             artifact.artifact_type in [:file, :plan, :workspace])
      end)
      |> Map.new(&{&1.path, &1.content_hash})

    incoming = Map.new(artifacts, &{artifact_value(&1, :path), artifact_value(&1, :content_hash)})

    Enum.reduce(incoming, %{added: 0, updated: 0, unchanged: 0}, fn {path, hash}, counts ->
      case Map.fetch(existing, path) do
        :error -> Map.update!(counts, :added, &(&1 + 1))
        {:ok, ^hash} -> Map.update!(counts, :unchanged, &(&1 + 1))
        {:ok, _old_hash} -> Map.update!(counts, :updated, &(&1 + 1))
      end
    end)
    |> Map.put(:removed, map_size(existing) - map_size(Map.take(existing, Map.keys(incoming))))
  end

  @doc "Upserts and reconciles project-level documents for an agent/project pair."
  def reconcile_project_documents(agent, project_key, documents) do
    upsert_result =
      Enum.reduce_while(documents, :ok, fn document, :ok ->
        content = artifact_value(document, :content, "")

        result =
          ProjectDocument
          |> Ash.Changeset.for_create(:upsert, %{
            agent: agent,
            project_key: project_key,
            path: artifact_value(document, :path),
            source_path: artifact_value(document, :source_path),
            content: content,
            content_hash: artifact_value(document, :content_hash) || content_hash(content),
            mime_type: artifact_value(document, :mime_type),
            modified_at: artifact_value(document, :modified_at),
            original_size: artifact_value(document, :original_size, byte_size(content)),
            stored_size: artifact_value(document, :stored_size, byte_size(content)),
            truncated: artifact_value(document, :truncated, false)
          })
          |> Ash.create()

        case result do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with :ok <- upsert_result do
      retained_paths = MapSet.new(documents, &artifact_value(&1, :path))

      removable =
        ProjectDocument
        |> Ash.Query.for_read(:for_project, %{agent: agent, project_key: project_key})
        |> Ash.read!()
        |> Enum.reject(&MapSet.member?(retained_paths, &1.path))

      Enum.each(removable, &Ash.destroy!/1)
      %{stored: length(documents), removed: length(removable)}
    end
  end

  @doc "Returns project documents associated with an agent/project key."
  def get_project_documents(agent, project_key) do
    ProjectDocument
    |> Ash.Query.for_read(:for_project, %{agent: agent, project_key: project_key})
    |> Ash.read!()
  end

  @impl true
  def get_artifacts(session_id) do
    SessionArtifact
    |> Ash.Query.for_read(:for_session, %{session_id: session_id})
    |> Ash.read!()
    |> Enum.map(fn a ->
      %JidoSessions.Artifact{
        path: a.path,
        artifact_type: a.artifact_type,
        content: a.content,
        content_hash: a.content_hash,
        size: a.size
      }
    end)
  end

  # ── Checkpoints ──

  @impl true
  def insert_checkpoints(session_id, checkpoints) do
    Enum.each(checkpoints, fn cp ->
      attrs = %{
        session_id: session_id,
        number: cp.number,
        title: cp.title,
        filename: cp[:filename],
        content: cp[:content],
        overview: cp[:overview],
        history: cp[:history],
        work_done: cp[:work_done],
        technical_details: cp[:technical_details],
        important_files: cp[:important_files],
        next_steps: cp[:next_steps]
      }

      changeset = Ash.Changeset.for_create(Checkpoint, :upsert, attrs)

      case Ash.create(changeset) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end)

    :ok
  end

  @impl true
  def get_checkpoints(session_id) do
    Checkpoint
    |> Ash.Query.for_read(:for_session, %{session_id: session_id})
    |> Ash.read!()
    |> Enum.map(fn cp ->
      %JidoSessions.Checkpoint{
        number: cp.number,
        title: cp.title,
        filename: cp.filename,
        content: cp.content
      }
    end)
  end

  # ── Todos ──

  @impl true
  def upsert_todos(session_id, todos) do
    Enum.each(todos, fn todo ->
      changeset =
        SessionTodo
        |> Ash.Changeset.for_create(:upsert, %{
          session_id: session_id,
          todo_id: todo.todo_id,
          title: todo.title,
          description: todo.description,
          status: to_string(todo.status),
          depends_on: todo.depends_on || []
        })

      case Ash.create(changeset) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end)

    :ok
  end

  @impl true
  def get_todos(session_id) do
    SessionTodo
    |> Ash.Query.for_read(:for_session, %{session_id: session_id})
    |> Ash.read!()
    |> Enum.map(fn t ->
      %JidoSessions.Todo{
        todo_id: t.todo_id,
        title: t.title,
        description: t.description,
        status: parse_status(t.status),
        depends_on: t.depends_on || []
      }
    end)
  end

  # ── Usage ──

  @impl true
  def insert_usage(session_id, entries) do
    Enum.each(entries, fn u ->
      UsageEntry
      |> Ash.Changeset.for_create(:create, %{
        session_id: session_id,
        model: u.model,
        input_tokens: u.input_tokens || 0,
        output_tokens: u.output_tokens || 0,
        cache_read_tokens: u.cache_read_tokens || 0,
        cache_write_tokens: u.cache_write_tokens || 0,
        cost: u.cost,
        duration_ms: u.duration_ms,
        initiator: u.initiator,
        timestamp: DateTime.utc_now()
      })
      |> Ash.create!()
    end)

    :ok
  end

  @impl true
  def get_usage(session_id) do
    UsageEntry
    |> Ash.Query.for_read(:for_session, %{session_id: session_id})
    |> Ash.read!()
    |> Enum.map(fn u ->
      %JidoSessions.Usage{
        model: u.model,
        input_tokens: u.input_tokens,
        output_tokens: u.output_tokens,
        cache_read_tokens: u.cache_read_tokens,
        cache_write_tokens: u.cache_write_tokens,
        cost: u.cost,
        duration_ms: u.duration_ms,
        initiator: u.initiator
      }
    end)
  end

  # ── Private helpers ──

  alias CopilotLv.Sessions.{SessionFile, SessionRef}

  @doc "Upsert session files (which files were touched during a session)."
  def upsert_session_files(session_id, files) do
    Enum.each(files, fn f ->
      changeset =
        Ash.Changeset.for_create(SessionFile, :upsert, %{
          session_id: session_id,
          file_path: f.file_path,
          tool_name: f[:tool_name],
          turn_index: f[:turn_index],
          first_seen_at: f[:first_seen_at]
        })

      case Ash.create(changeset) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end)

    :ok
  end

  @doc "Upsert session refs (git commits, PRs, issues referenced)."
  def upsert_session_refs(session_id, refs) do
    Enum.each(refs, fn r ->
      changeset =
        Ash.Changeset.for_create(SessionRef, :upsert, %{
          session_id: session_id,
          ref_type: r.ref_type,
          ref_value: r.ref_value,
          turn_index: r[:turn_index],
          created_at: r[:created_at]
        })

      case Ash.create(changeset) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end)

    :ok
  end

  defp session_to_attrs(%JidoSessions.Session{} = s) do
    %{
      id: s.id,
      cwd: s.cwd || "unknown",
      model: s.model,
      summary: s.summary,
      title: s.title,
      git_root: s.git_root,
      branch: s.branch,
      copilot_version: s.agent_version,
      source: s.source || :imported,
      status: s.status || :stopped,
      started_at: s.started_at,
      stopped_at: s.stopped_at,
      imported_at: DateTime.utc_now(),
      agent: s.agent,
      hostname: s.hostname
    }
  end

  defp db_to_session(%Session{} = s) do
    %JidoSessions.Session{
      id: s.id,
      agent: s.agent || :copilot,
      source: s.source,
      status: s.status,
      cwd: s.cwd,
      git_root: s.git_root,
      branch: s.branch,
      title: s.title,
      summary: s.summary,
      model: s.model,
      started_at: s.started_at,
      stopped_at: s.stopped_at,
      hostname: s.hostname,
      agent_version: s.copilot_version
    }
  end

  defp wrap_session({:ok, db_session}), do: {:ok, db_to_session(db_session)}
  defp wrap_session({:error, _} = err), do: err

  defp apply_filters(sessions, []), do: sessions

  defp apply_filters(sessions, [{:agent, agent} | rest]) do
    sessions |> Enum.filter(&(&1.agent == agent)) |> apply_filters(rest)
  end

  defp apply_filters(sessions, [{:status, status} | rest]) do
    sessions |> Enum.filter(&(&1.status == status)) |> apply_filters(rest)
  end

  defp apply_filters(sessions, [_ | rest]), do: apply_filters(sessions, rest)

  defp encode_data(nil), do: nil
  defp encode_data(data) when is_binary(data), do: data
  defp encode_data(data) when is_map(data), do: Jason.encode!(data)
  defp encode_data(data), do: inspect(data)

  defp content_hash(nil), do: nil

  defp content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp artifact_value(artifact, key, default \\ nil) do
    case Map.get(artifact, key) do
      nil -> default
      value -> value
    end
  end

  defp parse_status("pending"), do: :pending
  defp parse_status("in_progress"), do: :in_progress
  defp parse_status("done"), do: :done
  defp parse_status("blocked"), do: :blocked
  defp parse_status(other) when is_atom(other), do: other
  defp parse_status(_), do: :pending
end
