defmodule Mix.Tasks.Copilot.Handoff do
  @moduledoc """
  Render a markdown handoff document for a stored session.

  ## Usage

      mix copilot.handoff <session-ref>
      mix copilot.handoff <session-ref> --agent codex
      mix copilot.handoff <session-ref> --output /tmp/handoff.md
  """

  use Mix.Task

  alias CopilotLv.SessionHandoff

  @shortdoc "Render a markdown session handoff"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [
          agent: :string,
          output: :string,
          full_transcript: :boolean,
          max_command_output_chars: :integer,
          max_assistant_chars: :integer,
          relative_to: :string
        ]
      )

    session_ref =
      case positional do
        [value | _] ->
          value

        [] ->
          Mix.raise("Usage: mix copilot.handoff <session-ref> [--agent agent] [--output path]")
      end

    Mix.Task.run("app.start")

    case SessionHandoff.generate(session_ref, opts) do
      {:ok, %{markdown: markdown}} ->
        case Keyword.get(opts, :output) do
          nil -> IO.binwrite(markdown)
          path -> File.write!(path, markdown)
        end

      {:error, :not_found} ->
        Mix.raise("Session not found: #{session_ref}")

      {:error, {:ambiguous, ids}} ->
        Mix.raise("Ambiguous session reference #{session_ref}. Matches: #{Enum.join(ids, ", ")}")
    end
  end
end
