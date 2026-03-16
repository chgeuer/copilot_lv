defmodule CopilotLv.SessionRegistry do
  @moduledoc """
  Manages the lifecycle of Copilot sessions.

  Provides a DynamicSupervisor for SessionServer processes and a
  Registry for name-based lookup. Persists sessions to SQLite via Ash.
  """

  alias CopilotLv.Sessions.Session

  @doc "Start a new session. Returns `{:ok, id}` or `{:error, reason}`."
  def create_session(opts \\ []) do
    # Generate a UUID and use it as both the copilot session ID and our prefixed primary key
    copilot_uuid = generate_uuid()
    id = Session.prefixed_id(:copilot, copilot_uuid)
    opts = Keyword.put(opts, :id, id)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    model = Keyword.get(opts, :model)

    # Persist to DB
    Ash.create!(Session, %{id: id, cwd: cwd, model: model})

    case DynamicSupervisor.start_child(__MODULE__.Supervisor, {CopilotLv.SessionServer, opts}) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stop a session by ID."
  def stop_session(id) do
    case Registry.lookup(__MODULE__.Registry, id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__.Supervisor, pid)

        # Mark as stopped in DB
        case Ash.get(Session, id) do
          {:ok, session} ->
            Ash.update!(session, %{status: :stopped, stopped_at: DateTime.utc_now()},
              action: :update_status
            )

          _ ->
            :ok
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc "List all active session IDs (running processes)."
  def list_active_sessions do
    __MODULE__.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc "List all sessions from DB (active + historic)."
  def list_all_sessions do
    Ash.read!(Session, action: :list_all)
  end

  @doc "Check if a session process is running."
  def session_exists?(id) do
    Registry.lookup(__MODULE__.Registry, id) != []
  end

  @doc "Get a session record from DB."
  def get_session(id) do
    Ash.get(Session, id)
  end

  @session_state_dirs [
    Path.join(System.user_home!(), ".copilot/session-state"),
    Path.join(System.user_home!(), ".local/state/.copilot/session-state")
  ]

  @doc "Delete a session: stop if active, remove from DB (with related records), and remove disk directory."
  def delete_session(id) do
    case get_session(id) do
      {:ok, session} ->
        if session.starred do
          {:error, :starred}
        else
          do_delete_session(id, session)
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "Toggle the starred status of a session."
  def toggle_star(id) do
    case get_session(id) do
      {:ok, session} ->
        Ash.update!(session, %{starred: !session.starred}, action: :toggle_star)
        :ok

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp do_delete_session(id, session) do
    # Stop if running
    if session_exists?(id), do: stop_session(id)

    # Delete related records via Ecto queries
    import Ecto.Query
    repo = CopilotLv.Repo
    repo.delete_all(from(e in "events", where: e.session_id == ^id))
    repo.delete_all(from(u in "usage_entries", where: u.session_id == ^id))
    repo.delete_all(from(c in "checkpoints", where: c.session_id == ^id))
    repo.delete_all(from(t in "session_todos", where: t.session_id == ^id))
    repo.delete_all(from(a in "session_artifacts", where: a.session_id == ^id))

    # Delete the session itself
    Ash.destroy!(session)

    # Delete from agent source DB (codex threads table + rollout file)
    agent = Session.agent_from_id(id)
    provider_id = Session.provider_id(id)

    if agent == :codex && provider_id do
      CopilotLv.Agents.Codex.delete_from_source(provider_id)
    end

    # Delete disk directory based on provider ID extracted from prefixed session ID
    if provider_id do
      Enum.each(@session_state_dirs, fn base_dir ->
        dir = Path.join(base_dir, provider_id)

        if File.dir?(dir) do
          File.rm_rf!(dir)
        end
      end)
    end

    :ok
  end

  @doc "Resume a stopped session. Starts a new SessionServer with the same ID."
  def resume_session(id) do
    case get_session(id) do
      {:ok, session} ->
        # Update status in DB
        Ash.update!(session, %{status: :starting, stopped_at: nil}, action: :update_status)

        opts = [
          id: id,
          cwd: session.cwd,
          model: session.model
        ]

        case DynamicSupervisor.start_child(__MODULE__.Supervisor, {CopilotLv.SessionServer, opts}) do
          {:ok, _pid} -> {:ok, id}
          {:error, reason} -> {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  defp generate_uuid do
    <<a::32, b::16, _c_high::4, c::12, _d_high::2, d::14, e::48>> =
      :crypto.strong_rand_bytes(16)

    # Set version 4 and variant bits
    raw = <<a::32, b::16, 4::4, c::12, 2::2, d::14, e::48>>

    raw
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp format_uuid(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>) do
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
