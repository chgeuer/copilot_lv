defmodule CopilotLv.Agents.Pi do
  @moduledoc """
  Agent parser for Pi AI CLI sessions.

  Pi stores sessions under `~/.pi/agent/sessions/` with this structure:

      sessions/
      ├── session-index.sqlite
      └── --{encoded-cwd}--/
          └── {timestamp}_{uuid}.jsonl

  Each JSONL file is an append-only log with a `session` header followed by
  `message`, `model_change`, `thinking_level_change`, and other entry types.
  """

  @behaviour JidoSessions.AgentParser

  alias Jido.PI.SessionStore
  alias Jido.PI.SessionStore.{JSONL, PathEncoder}

  @impl true
  def agent_type, do: :pi

  @impl true
  def remote_well_known_dirs do
    ["~/.pi/agent/sessions"]
  end

  @impl true
  def well_known_dirs do
    [Path.expand("~/.pi/agent/sessions")]
  end

  @impl true
  def discover_sessions(base_dir) do
    if File.dir?(base_dir) do
      base_dir
      |> File.ls!()
      |> Enum.filter(fn name ->
        PathEncoder.encoded?(name) and File.dir?(Path.join(base_dir, name))
      end)
      |> Enum.flat_map(fn folder ->
        folder_path = Path.join(base_dir, folder)

        folder_path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn filename ->
          session_id = extract_session_id(filename)
          {session_id, Path.join(folder_path, filename)}
        end)
      end)
      |> Enum.sort()
    else
      []
    end
  end

  @impl true
  def parse_session(jsonl_path) do
    case SessionStore.read_session(jsonl_path) do
      {:ok, session} ->
        {:ok,
         %{
           session_id: session.session_id,
           cwd: session.cwd,
           model: session.model,
           summary: session.summary,
           title: session.title,
           git_root: session.git_root,
           branch: session.branch,
           agent_version: session.agent_version,
           started_at: session.started_at,
           stopped_at: session.stopped_at,
           events: session.events
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Exports a session from copilot_lv events back to Pi's JSONL format.

  Takes the session's events (as stored in copilot_lv DB) and writes them
  as a Pi-format JSONL file, updating the SQLite index.
  """
  @spec export_session(String.t(), [map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def export_session(session_id, events, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, SessionStore.default_base_dir())
    entries = SessionStore.events_to_entries(events)

    header = JSONL.extract_header(entries)

    if header do
      SessionStore.write_session(base_dir, session_id, entries, opts)
    else
      {:error, :no_session_header_in_events}
    end
  end

  defp extract_session_id(filename) do
    filename
    |> String.trim_trailing(".jsonl")
    |> String.split("_", parts: 2)
    |> case do
      [_timestamp, uuid] -> uuid
      [single] -> single
    end
  end
end
