defmodule Mix.Tasks.Copilot.Conversations do
  @moduledoc """
  Export session conversations as clean markdown files (user ↔ assistant only).

  For a given working directory, finds all sessions that ran there and writes
  one markdown file per session containing timestamped user and assistant
  messages — no tool calls, no internal operations.

  ## Usage

      mix copilot.conversations --cwd /path/to/project --output /tmp/conversations
      mix copilot.conversations --cwd . --output ./conversations --agent claude
      mix copilot.conversations --cwd /my/project --output ./out --verbose

  ## Options

    * `--cwd`     - Working directory to match sessions against (required)
    * `--output`  - Directory to write markdown files into (required)
    * `--agent`   - Filter to a specific agent (copilot, claude, codex, gemini)
    * `--host`    - Filter to a specific hostname
    * `--dry-run` - Preview which files would be written without writing
    * `--verbose` - Print details for each exported session

  ## Output

  Files are named `{timestamp}_{agent}.md`, e.g. `2026-03-09T11-37-14_claude.md`.
  Each file contains YAML front matter and a chronological conversation transcript
  with timestamps for every user and assistant turn.
  """

  use Mix.Task

  alias CopilotLv.SessionHandoff.Extractor
  alias CopilotLv.Sessions.{Event, Session}

  require Ash.Query

  @shortdoc "Export session conversations as markdown"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          cwd: :string,
          output: :string,
          agent: :string,
          host: :string,
          dry_run: :boolean,
          verbose: :boolean
        ]
      )

    cwd = Keyword.get(opts, :cwd) || Mix.raise("--cwd is required")
    output = Keyword.get(opts, :output) || Mix.raise("--output is required")
    dry_run = Keyword.get(opts, :dry_run, false)
    verbose = Keyword.get(opts, :verbose, false)
    agent_filter = normalize_agent(Keyword.get(opts, :agent))
    host_filter = Keyword.get(opts, :host)

    cwd = Path.expand(cwd)

    Mix.Task.run("app.start")

    sessions =
      Session
      |> Ash.Query.for_read(:list_all)
      |> Ash.Query.filter(cwd: cwd)
      |> Ash.read!()
      |> maybe_filter_agent(agent_filter)
      |> maybe_filter_host(host_filter)
      |> Enum.sort_by(fn s -> s.started_at || ~U[1970-01-01 00:00:00Z] end, DateTime)

    dry = if dry_run, do: "[DRY RUN] ", else: ""
    Mix.shell().info("#{dry}Found #{length(sessions)} sessions for #{cwd}")

    unless dry_run, do: File.mkdir_p!(output)

    stats =
      Enum.reduce(sessions, %{exported: 0, skipped: 0}, fn session, stats ->
        case export_conversation(session, output, dry_run, verbose) do
          {:ok, filename} ->
            if verbose, do: Mix.shell().info("  ✓ #{filename}")
            %{stats | exported: stats.exported + 1}

          :skipped ->
            if verbose,
              do: Mix.shell().info("  ⊘ #{session.id} — no conversation turns")

            %{stats | skipped: stats.skipped + 1}
        end
      end)

    Mix.shell().info("""
    \n#{dry}Done:
      #{stats.exported} conversations exported
      #{stats.skipped} sessions skipped (no conversation)
      Output: #{output}
    """)
  end

  defp export_conversation(session, output_dir, dry_run, _verbose) do
    events = load_events(session)
    extracted = Extractor.extract(session, events)

    transcript = build_transcript(extracted)

    if transcript == [] do
      :skipped
    else
      markdown = render_conversation(session, transcript)
      filename = build_filename(session)
      path = Path.join(output_dir, filename)

      unless dry_run, do: File.write!(path, markdown)

      {:ok, filename}
    end
  end

  defp load_events(session) do
    Event
    |> Ash.Query.for_read(:for_session, %{session_id: session.id})
    |> Ash.read!()
    |> Enum.map(fn event ->
      data = normalize_event_data(session.agent, event.event_type, event.data || %{})

      %{
        id: event.id,
        type: event.event_type,
        data: data,
        sequence: event.sequence,
        timestamp: event.timestamp
      }
    end)
    |> Enum.sort_by(& &1.sequence)
  end

  defp normalize_event_data(:copilot, event_type, data) when is_map(data) do
    if is_map(data["data"]) && data["type"] == event_type do
      data["data"]
    else
      data
    end
  end

  defp normalize_event_data(_agent, _event_type, data), do: data

  defp build_transcript(extracted) do
    user_entries =
      Enum.map(extracted.prompts, fn prompt ->
        %{role: :user, sequence: prompt.sequence, timestamp: prompt.timestamp, text: prompt.text}
      end)

    assistant_entries =
      Enum.map(extracted.assistant_outputs, fn output ->
        %{
          role: :assistant,
          sequence: output.sequence_start,
          timestamp: output.timestamp,
          text: output.text
        }
      end)

    (user_entries ++ assistant_entries)
    |> Enum.reject(&is_nil(&1.text))
    |> Enum.reject(&(String.trim(&1.text) == ""))
    |> Enum.sort_by(&{&1.sequence, role_order(&1.role)})
    |> consolidate_consecutive_assistant_entries()
  end

  defp consolidate_consecutive_assistant_entries(entries) do
    entries
    |> Enum.chunk_while(
      nil,
      fn entry, acc ->
        case {acc, entry.role} do
          {nil, _} ->
            {:cont, entry}

          {%{role: :assistant}, :assistant} ->
            merged = %{
              acc
              | text: acc.text <> "\n\n" <> entry.text,
                sequence: acc.sequence
            }

            {:cont, merged}

          {_, _} ->
            {:cont, acc, entry}
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, acc, nil}
      end
    )
  end

  defp role_order(:user), do: 0
  defp role_order(:assistant), do: 1

  defp render_conversation(session, transcript) do
    front_matter = render_front_matter(session)
    turns = render_turns(transcript)

    [front_matter, "", turns]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp render_front_matter(session) do
    [
      "---",
      "session_id: #{yaml_scalar(session.id)}",
      "agent: #{yaml_scalar(session.agent)}",
      "hostname: #{yaml_scalar(session.hostname)}",
      "cwd: #{yaml_scalar(session.cwd)}",
      "branch: #{yaml_scalar(session.branch)}",
      "model: #{yaml_scalar(session.model)}",
      "started_at: #{yaml_scalar(format_timestamp(session.started_at))}",
      "stopped_at: #{yaml_scalar(format_timestamp(session.stopped_at))}",
      "title: #{yaml_scalar(session.title)}",
      "---",
      ""
    ]
    |> Enum.join("\n")
  end

  defp render_turns(transcript) do
    transcript
    |> Enum.map(fn entry ->
      heading = turn_heading(entry)

      [heading, "", entry.text, ""]
      |> Enum.join("\n")
    end)
    |> Enum.join("\n")
  end

  defp turn_heading(%{role: :user, timestamp: ts}) do
    "## User — #{format_timestamp(ts)}"
  end

  defp turn_heading(%{role: :assistant, timestamp: ts}) do
    "## Assistant — #{format_timestamp(ts)}"
  end

  defp build_filename(session) do
    ts =
      case session.started_at do
        %DateTime{} = dt ->
          dt
          |> DateTime.to_iso8601()
          |> String.slice(0, 19)
          |> String.replace(":", "-")

        _ ->
          "unknown"
      end

    agent = session.agent || :unknown

    "#{ts}_#{agent}_#{session.id}.md"
  end

  defp maybe_filter_agent(sessions, nil), do: sessions

  defp maybe_filter_agent(sessions, agent) do
    Enum.filter(sessions, &(&1.agent == agent))
  end

  defp maybe_filter_host(sessions, nil), do: sessions
  defp maybe_filter_host(sessions, host), do: Enum.filter(sessions, &(&1.hostname == host))

  defp normalize_agent(nil), do: nil

  defp normalize_agent(agent) when is_binary(agent) do
    case String.downcase(agent) do
      "copilot" -> :copilot
      "claude" -> :claude
      "codex" -> :codex
      "gemini" -> :gemini
      _ -> Mix.raise("Unknown agent: #{agent}. Expected copilot, claude, codex, or gemini.")
    end
  end

  defp format_timestamp(nil), do: "unknown"
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(value), do: to_string(value)

  defp yaml_scalar(nil), do: "null"
  defp yaml_scalar(value) when is_atom(value), do: yaml_scalar(to_string(value))
  defp yaml_scalar(value) when is_binary(value), do: Jason.encode!(value)
  defp yaml_scalar(value), do: to_string(value)
end
