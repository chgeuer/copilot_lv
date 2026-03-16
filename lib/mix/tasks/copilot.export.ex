defmodule Mix.Tasks.Copilot.Export do
  @moduledoc """
  Export sessions from the database back to their native agent format on disk.

  Supports round-trip: import → database → export produces files that can be
  read by the original agent CLI.

  ## Usage

      mix copilot.export                         # Export all agents to default dirs
      mix copilot.export --agent claude           # Export only Claude sessions
      mix copilot.export --target ~/restored      # Export to custom base dir
      mix copilot.export --host beast             # Export only sessions from host
      mix copilot.export --dry-run                # Preview without writing

  ## Agent export formats

    * **Claude**: `{target}/.claude/projects/{encoded-cwd}/{session-id}.jsonl`
    * **Codex**: `{target}/.codex/sessions/{year}/{month}/{day}/rollout-{date}-{session-id}.jsonl`
    * **Gemini**: `{target}/.gemini/tmp/{project-hash}/chats/session-{date}-{short-id}.json`
    * **Copilot**: Uses existing `extract_sessions.sh`
  """

  use Mix.Task

  @shortdoc "Export sessions back to native agent format"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          agent: :string,
          target: :string,
          host: :string,
          dry_run: :boolean,
          verbose: :boolean
        ]
      )

    Mix.Task.run("app.start")

    target = Keyword.get(opts, :target, Path.expand("~/restored-sessions"))
    dry_run = Keyword.get(opts, :dry_run, false)
    verbose = Keyword.get(opts, :verbose, false)
    agent_filter = Keyword.get(opts, :agent)
    host_filter = Keyword.get(opts, :host)

    sessions = CopilotLv.Sessions.Session |> Ash.read!()

    sessions =
      sessions
      |> maybe_filter_agent(agent_filter)
      |> maybe_filter_host(host_filter)

    dry = if dry_run, do: "[DRY RUN] ", else: ""
    Mix.shell().info("#{dry}Exporting #{length(sessions)} sessions to #{target}")

    stats = %{exported: 0, skipped: 0, errors: 0}

    stats =
      Enum.reduce(sessions, stats, fn session, stats ->
        case export_session(session, target, dry_run, verbose) do
          :ok ->
            %{stats | exported: stats.exported + 1}

          {:error, reason} ->
            if verbose,
              do: Mix.shell().error("  Error #{session.id}: #{inspect(reason)}")

            %{stats | errors: stats.errors + 1}
        end
      end)

    Mix.shell().info("""
    \n#{dry}Export complete:
      #{stats.exported} sessions exported
      #{stats.errors} errors
    """)
  end

  defp maybe_filter_agent(sessions, nil), do: sessions

  defp maybe_filter_agent(sessions, agent) do
    atom = String.to_existing_atom(agent)
    Enum.filter(sessions, &(&1.agent == atom))
  end

  defp maybe_filter_host(sessions, nil), do: sessions
  defp maybe_filter_host(sessions, host), do: Enum.filter(sessions, &(&1.hostname == host))

  defp export_session(session, target, dry_run, verbose) do
    events =
      CopilotLv.Sessions.Event
      |> Ash.Query.for_read(:for_session, %{session_id: session.id})
      |> Ash.read!()
      |> Enum.sort_by(& &1.sequence)

    case session.agent do
      :claude -> export_claude(session, events, target, dry_run, verbose)
      :codex -> export_codex(session, events, target, dry_run, verbose)
      :gemini -> export_gemini(session, events, target, dry_run, verbose)
      :copilot -> export_copilot(session, events, target, dry_run, verbose)
      _ -> {:error, :unknown_agent}
    end
  end

  defp export_claude(session, events, target, dry_run, verbose) do
    provider_id = CopilotLv.Sessions.Session.provider_id(session.id)
    # Reconstruct: {target}/.claude/projects/{encoded-cwd}/{session-id}.jsonl
    encoded_cwd = encode_claude_project_dir(session.cwd || "unknown")
    dir = Path.join([target, ".claude", "projects", encoded_cwd])
    file = Path.join(dir, "#{provider_id}.jsonl")

    lines =
      Enum.map(events, fn e ->
        data = if is_binary(e.data), do: Jason.decode!(e.data), else: e.data
        Jason.encode!(data)
      end)

    if verbose, do: Mix.shell().info("  #{session.agent} #{provider_id} → #{file}")

    unless dry_run do
      File.mkdir_p!(dir)
      File.write!(file, Enum.join(lines, "\n") <> "\n")
    end

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp export_codex(session, events, target, dry_run, verbose) do
    provider_id = CopilotLv.Sessions.Session.provider_id(session.id)
    # Reconstruct: {target}/.codex/sessions/{year}/{month}/{day}/rollout-{date}-{session-id}.jsonl
    ts = session.started_at || DateTime.utc_now()
    date_str = Calendar.strftime(ts, "%Y-%m-%dT%H-%M-%S")
    year = Calendar.strftime(ts, "%Y")
    month = Calendar.strftime(ts, "%m")
    day = Calendar.strftime(ts, "%d")

    dir = Path.join([target, ".codex", "sessions", year, month, day])
    file = Path.join(dir, "rollout-#{date_str}-#{provider_id}.jsonl")

    lines =
      Enum.map(events, fn e ->
        data = if is_binary(e.data), do: Jason.decode!(e.data), else: e.data
        Jason.encode!(data)
      end)

    if verbose, do: Mix.shell().info("  #{session.agent} #{provider_id} → #{file}")

    unless dry_run do
      File.mkdir_p!(dir)
      File.write!(file, Enum.join(lines, "\n") <> "\n")
    end

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp export_gemini(session, events, target, dry_run, verbose) do
    provider_id = CopilotLv.Sessions.Session.provider_id(session.id)
    # Reconstruct: {target}/.gemini/tmp/{project-hash}/chats/session-{date}-{short-id}.json
    ts = session.started_at || DateTime.utc_now()
    date_str = Calendar.strftime(ts, "%Y-%m-%dT%H-%M")
    short_id = String.slice(provider_id, 0, 8)
    project_hash = :crypto.hash(:sha256, session.cwd || "unknown") |> Base.encode16(case: :lower)

    dir = Path.join([target, ".gemini", "tmp", project_hash, "chats"])
    file = Path.join(dir, "session-#{date_str}-#{short_id}.json")

    # Reconstruct the JSON document from session_meta envelope + message events
    {envelope, message_events} =
      case events do
        [%{event_type: "session_meta"} = meta | rest] ->
          meta_data = if is_binary(meta.data), do: Jason.decode!(meta.data), else: meta.data
          {meta_data, rest}

        _ ->
          {%{"sessionId" => provider_id}, events}
      end

    messages =
      Enum.map(message_events, fn e ->
        if is_binary(e.data), do: Jason.decode!(e.data), else: e.data
      end)

    doc = Map.put(envelope, "messages", messages)

    if verbose, do: Mix.shell().info("  #{session.agent} #{provider_id} → #{file}")

    unless dry_run do
      File.mkdir_p!(dir)
      File.write!(file, Jason.encode!(doc, pretty: true))
    end

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp export_copilot(session, events, target, dry_run, verbose) do
    provider_id = CopilotLv.Sessions.Session.provider_id(session.id)
    # Reconstruct: {target}/.copilot/session-state/{session-id}/events.jsonl
    dir = Path.join([target, ".copilot", "session-state", provider_id])
    file = Path.join(dir, "events.jsonl")

    lines =
      Enum.map(events, fn e ->
        data = if is_binary(e.data), do: Jason.decode!(e.data), else: e.data

        %{
          "type" => e.event_type,
          "id" => e.event_id,
          "parentId" => e.parent_event_id,
          "data" => data,
          "timestamp" => if(e.timestamp, do: DateTime.to_iso8601(e.timestamp))
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
        |> Jason.encode!()
      end)

    if verbose, do: Mix.shell().info("  #{session.agent} #{provider_id} → #{file}")

    unless dry_run do
      File.mkdir_p!(dir)
      File.write!(file, Enum.join(lines, "\n") <> "\n")
    end

    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp encode_claude_project_dir(cwd) do
    cwd
    |> String.trim_leading("/")
    |> String.replace("/", "-")
    |> then(&("-" <> &1))
  end
end
