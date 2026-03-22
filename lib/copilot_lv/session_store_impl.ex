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
    SessionTodo,
    UsageEntry
  }

  # ── Sessions ──

  @impl true
  def upsert_session(session) do
    attrs = session_to_attrs(session)
    prefixed_id = attrs.id

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

    Repo.one(from e in "events", where: e.session_id == ^session_id, select: count())
  end

  # ── Artifacts ──

  @impl true
  def upsert_artifacts(session_id, artifacts) do
    Enum.each(artifacts, fn art ->
      changeset =
        SessionArtifact
        |> Ash.Changeset.for_create(:upsert, %{
          session_id: session_id,
          path: art.path,
          content: art.content,
          content_hash: art.content_hash || content_hash(art.content),
          size: art.size || byte_size(art.content || ""),
          artifact_type: art.artifact_type
        })

      case Ash.create(changeset) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end)

    :ok
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
      Checkpoint
      |> Ash.Changeset.for_create(:create, %{
        session_id: session_id,
        number: cp.number,
        title: cp.title,
        filename: cp.filename,
        content: cp.content
      })
      |> Ash.create!()
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
      event_count: 0,
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

  defp encode_data(data) when is_binary(data), do: data
  defp encode_data(data) when is_map(data), do: Jason.encode!(data)
  defp encode_data(data), do: inspect(data)

  defp content_hash(nil), do: nil

  defp content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp parse_status("pending"), do: :pending
  defp parse_status("in_progress"), do: :in_progress
  defp parse_status("done"), do: :done
  defp parse_status("blocked"), do: :blocked
  defp parse_status(other) when is_atom(other), do: other
  defp parse_status(_), do: :pending
end
