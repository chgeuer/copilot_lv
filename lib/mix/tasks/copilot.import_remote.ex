defmodule Mix.Tasks.Copilot.ImportRemote do
  @moduledoc """
  Import agent sessions from a remote computer via SSH.

  ## Usage

      mix copilot.import_remote beast                      # All agents from beast
      mix copilot.import_remote beast --agent claude        # Only Claude sessions
      mix copilot.import_remote framedesk --agent codex     # Only Codex from framedesk
      mix copilot.import_remote beast --dir ~/.claude       # Look in specific directory
      mix copilot.import_remote beast --verbose --dry-run   # Preview what would import

  The hostname is resolved via ~/.ssh/config.
  """

  use Mix.Task

  @shortdoc "Import agent sessions from a remote host via SSH"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [
          verbose: :boolean,
          dry_run: :boolean,
          agent: :string,
          dir: :keep,
          force: :boolean
        ]
      )

    hostname =
      case positional do
        [h | _] ->
          h

        [] ->
          Mix.shell().error(
            "Usage: mix copilot.import_remote <hostname> [--agent x] [--dir path]"
          )

          exit({:shutdown, 1})
      end

    Mix.Task.run("app.start")

    agent =
      case Keyword.get(opts, :agent) do
        nil -> :all
        "all" -> :all
        name -> String.to_existing_atom(name)
      end

    extra_dirs = Keyword.get_values(opts, :dir)

    dry = if Keyword.get(opts, :dry_run, false), do: "[DRY RUN] ", else: ""

    Mix.shell().info("#{dry}Importing from #{hostname}...")

    stats =
      CopilotLv.AgentDiscovery.import_remote(hostname, agent,
        verbose: Keyword.get(opts, :verbose, false),
        dry_run: Keyword.get(opts, :dry_run, false),
        force: Keyword.get(opts, :force, false),
        dirs: extra_dirs
      )

    Mix.shell().info("""
    \n#{dry}Remote import complete (#{hostname}):
      #{stats.imported} sessions imported
      #{stats.repaired} sessions repaired
      #{stats.skipped} sessions skipped
      #{stats.errors} errors
    """)
  end
end
