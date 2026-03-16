defmodule Mix.Tasks.Copilot.Sync do
  @moduledoc """
  Import agent session history into the local database.

  Supports Copilot, Claude, Codex, and Gemini sessions.

  ## Usage

      mix copilot.sync                      # Import all agents
      mix copilot.sync --agent copilot      # Import only Copilot sessions
      mix copilot.sync --agent claude       # Import only Claude sessions
      mix copilot.sync --verbose            # Show per-session details
      mix copilot.sync --dry-run            # Show what would be imported
  """

  use Mix.Task

  @shortdoc "Import agent session history"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [verbose: :boolean, dry_run: :boolean, agent: :string]
      )

    Mix.Task.run("app.start")

    agent =
      case Keyword.get(opts, :agent) do
        nil -> :all
        "all" -> :all
        name -> String.to_existing_atom(name)
      end

    # Run the original Copilot sync for copilot sessions (preserves full feature set)
    if agent in [:all, :copilot] do
      case CopilotLv.Sync.run(opts) do
        {:ok, stats} ->
          dry = if Keyword.get(opts, :dry_run, false), do: "[DRY RUN] ", else: ""

          Mix.shell().info("""
          \n#{dry}Copilot sync complete:
            #{stats.imported} sessions imported
            #{stats.updated} sessions updated
            #{stats.skipped} sessions skipped
            #{stats.errors} errors
            #{stats.events} total events
          """)

        {:error, msg} ->
          Mix.shell().error("Copilot sync: #{msg}")
      end
    end

    # Run multi-agent import for non-copilot agents
    agents_to_import =
      case agent do
        :all -> [:claude, :codex, :gemini]
        :copilot -> []
        other -> [other]
      end

    Enum.each(agents_to_import, fn agent_type ->
      dry = if Keyword.get(opts, :dry_run, false), do: "[DRY RUN] ", else: ""
      stats = CopilotLv.AgentDiscovery.import_local(agent_type, opts)

      Mix.shell().info("""
      \n#{dry}#{agent_type} sync complete:
        #{stats.imported} sessions imported
        #{stats.repaired} sessions repaired
        #{stats.skipped} sessions skipped
        #{stats.errors} errors
      """)
    end)
  end
end
