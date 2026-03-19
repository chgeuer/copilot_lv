defmodule CopilotLv.Agents do
  @moduledoc """
  Agent parser registry. Delegates to JidoSessions.AgentParsers for
  Copilot, Claude, and Gemini. Codex and Pi remain local due to
  app-specific dependencies (Exqlite/CopilotLv.Repo and jido_pi).
  """

  @doc "Returns all registered agent modules."
  def all do
    [
      JidoSessions.AgentParsers.Copilot,
      JidoSessions.AgentParsers.Claude,
      CopilotLv.Agents.Codex,
      JidoSessions.AgentParsers.Gemini,
      CopilotLv.Agents.Pi
    ]
  end

  @doc "Returns the agent module for a given type atom."
  def for_type(:copilot), do: JidoSessions.AgentParsers.Copilot
  def for_type(:claude), do: JidoSessions.AgentParsers.Claude
  def for_type(:codex), do: CopilotLv.Agents.Codex
  def for_type(:gemini), do: JidoSessions.AgentParsers.Gemini
  def for_type(:pi), do: CopilotLv.Agents.Pi
  def for_type(_), do: nil

  @doc "Parses a session file using the appropriate agent parser."
  def parse_session(agent, path) do
    case for_type(agent) do
      nil -> {:error, :unknown_agent}
      mod -> mod.parse_session(path)
    end
  end

  @doc "Discovers sessions across all agents, or a specific one, in well-known dirs."
  def discover_local(agent \\ :all) do
    modules = if agent == :all, do: all(), else: [for_type(agent)]
    JidoSessions.AgentParser.discover_local(modules)
  end
end
