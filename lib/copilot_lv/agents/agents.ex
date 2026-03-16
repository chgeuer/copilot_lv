defmodule CopilotLv.Agents do
  @moduledoc """
  Behaviour for agent session parsers.

  Each agent (Copilot, Claude, Codex, Gemini) implements this behaviour
  to discover and parse session files from their well-known directories.
  """

  @type session_id :: String.t()
  @type parsed_event :: %{
          type: String.t(),
          data: map(),
          timestamp: DateTime.t() | nil,
          sequence: non_neg_integer()
        }

  @type parsed_session :: %{
          session_id: session_id(),
          cwd: String.t() | nil,
          model: String.t() | nil,
          summary: String.t() | nil,
          title: String.t() | nil,
          git_root: String.t() | nil,
          branch: String.t() | nil,
          agent_version: String.t() | nil,
          started_at: DateTime.t() | nil,
          stopped_at: DateTime.t() | nil,
          events: [parsed_event()]
        }

  @doc "Returns the agent type atom."
  @callback agent_type() :: :copilot | :claude | :codex | :gemini

  @doc "Returns a list of well-known directories where this agent stores sessions."
  @callback well_known_dirs() :: [String.t()]

  @doc """
  Returns generic well-known directory patterns suitable for remote hosts.
  Uses `~` for home directory so the remote shell can expand it.
  Defaults to `well_known_dirs/0` if not implemented.
  """
  @callback remote_well_known_dirs() :: [String.t()]
  @optional_callbacks [remote_well_known_dirs: 0]

  @doc """
  Discovers all session files in the given base directory.
  Returns a list of `{session_id, file_path}` tuples.
  """
  @callback discover_sessions(base_dir :: String.t()) :: [{session_id(), String.t()}]

  @doc """
  Parses a session file (or directory) at the given path into a normalized struct.
  """
  @callback parse_session(path :: String.t()) :: {:ok, parsed_session()} | {:error, term()}

  @doc "Returns all registered agent modules."
  def all do
    [
      CopilotLv.Agents.Copilot,
      CopilotLv.Agents.Claude,
      CopilotLv.Agents.Codex,
      CopilotLv.Agents.Gemini
    ]
  end

  @doc "Returns the agent module for a given type atom."
  def for_type(:copilot), do: CopilotLv.Agents.Copilot
  def for_type(:claude), do: CopilotLv.Agents.Claude
  def for_type(:codex), do: CopilotLv.Agents.Codex
  def for_type(:gemini), do: CopilotLv.Agents.Gemini
  def for_type(_), do: nil

  @doc "Parses a session file using the appropriate agent parser."
  def parse_session(:copilot, path), do: CopilotLv.Agents.Copilot.parse_session(path)
  def parse_session(:claude, path), do: CopilotLv.Agents.Claude.parse_session(path)
  def parse_session(:codex, path), do: CopilotLv.Agents.Codex.parse_session(path)
  def parse_session(:gemini, path), do: CopilotLv.Agents.Gemini.parse_session(path)
  def parse_session(_, _), do: {:error, :unknown_agent}

  @doc "Discovers sessions across all agents, or a specific one, in well-known dirs."
  def discover_local(agent \\ :all) do
    modules = if agent == :all, do: all(), else: [for_type(agent)]

    Enum.flat_map(modules, fn mod ->
      mod.well_known_dirs()
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(fn dir ->
        mod.discover_sessions(dir)
        |> Enum.map(fn {sid, path} -> {mod.agent_type(), sid, path, dir} end)
      end)
    end)
  end
end
