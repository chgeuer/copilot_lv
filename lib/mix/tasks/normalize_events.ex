defmodule Mix.Tasks.NormalizeEvents do
  @moduledoc """
  Normalizes existing native-format events in the database to the canonical vocabulary.

  This is a one-time migration task. After running, all events in the database
  will use the canonical copilot event vocabulary regardless of their source agent.

  ## Usage

      mix normalize_events           # normalize all non-copilot sessions
      mix normalize_events --agent claude   # normalize only claude sessions
      mix normalize_events --dry-run        # preview without writing
  """
  use Mix.Task

  @shortdoc "Normalizes agent-native events to canonical vocabulary"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [agent: :string, dry_run: :boolean],
        aliases: [a: :agent, n: :dry_run]
      )

    Mix.Task.run("app.start")

    agent_filter = opts[:agent] && String.to_existing_atom(opts[:agent])
    dry_run = opts[:dry_run] || false

    if dry_run, do: Mix.shell().info("DRY RUN — no changes will be written\n")

    agents = if agent_filter, do: [agent_filter], else: [:claude, :codex, :gemini, :pi]

    Enum.each(agents, fn agent ->
      normalize_agent(agent, dry_run)
    end)

    Mix.shell().info("\nDone!")
  end

  defp normalize_agent(agent, dry_run) do
    alias CopilotLv.Repo
    import Ecto.Query

    Mix.shell().info("── #{agent} ──")

    # Find sessions for this agent
    sessions =
      Repo.all(
        from(s in "sessions",
          where: s.agent == ^to_string(agent),
          select: %{id: s.id},
          order_by: s.id
        )
      )

    Mix.shell().info("  Found #{length(sessions)} sessions")

    total_updated = 0
    total_deleted = 0
    total_inserted = 0

    {total_updated, total_deleted, total_inserted} =
      Enum.reduce(sessions, {total_updated, total_deleted, total_inserted}, fn session,
                                                                               {upd, del, ins} ->
        normalize_session(session.id, agent, dry_run, {upd, del, ins})
      end)

    Mix.shell().info(
      "  Summary: #{total_updated} updated, #{total_deleted} deleted, #{total_inserted} inserted"
    )
  end

  defp normalize_session(session_id, agent, dry_run, {upd, del, ins}) do
    alias CopilotLv.Repo
    import Ecto.Query

    # Load existing events
    events =
      Repo.all(
        from(e in "events",
          where: e.session_id == ^session_id,
          order_by: e.sequence,
          select: %{
            id: e.id,
            event_type: e.event_type,
            data: e.data,
            raw_data: e.raw_data,
            timestamp: e.timestamp,
            sequence: e.sequence
          }
        )
      )

    if events == [] do
      {upd, del, ins}
    else
      # Check if this session has native-format events that need normalization
      has_native =
        Enum.any?(events, fn e ->
          e.event_type in native_types_for(agent)
        end)

      if !has_native do
        # Already canonical
        {upd, del, ins}
      else
        # Build raw events in the format the normalizer expects.
        # Inject _source_sequence so we can trace fan-out events back to their original.
        raw_events =
          Enum.map(events, fn e ->
            data = parse_data(e.data)

            %{
              type: e.event_type,
              data: data,
              timestamp: parse_timestamp(e.timestamp),
              sequence: e.sequence,
              _source_sequence: e.sequence
            }
          end)

        # Build a lookup from sequence → raw_data (pre-normalization data for round-trip)
        raw_data_by_seq =
          Map.new(events, fn e ->
            {e.sequence, e.raw_data || e.data}
          end)

        # Normalize
        normalized = JidoSessions.EventNormalizer.normalize_events(agent, raw_events)

        if dry_run do
          old_types = events |> Enum.map(& &1.event_type) |> Enum.frequencies()
          new_types = normalized |> Enum.map(& &1.type) |> Enum.frequencies()

          if old_types != new_types do
            Mix.shell().info("  #{session_id}: #{length(events)} → #{length(normalized)} events")

            # Show type changes
            all_types =
              MapSet.union(MapSet.new(Map.keys(old_types)), MapSet.new(Map.keys(new_types)))

            Enum.each(Enum.sort(all_types), fn t ->
              old = Map.get(old_types, t, 0)
              new = Map.get(new_types, t, 0)

              if old != new do
                Mix.shell().info("    #{t}: #{old} → #{new}")
              end
            end)
          end

          {upd, del, ins}
        else
          # Delete existing events and insert normalized ones
          {deleted, _} =
            Repo.query!("DELETE FROM events WHERE session_id = ?1", [session_id])
            |> then(fn _ -> {length(events), nil} end)

          entries =
            Enum.map(normalized, fn event ->
              # Look up raw_data from the source event (before fan-out/normalization)
              source_seq = Map.get(event, :_source_sequence, event.sequence)
              raw_data = Map.get(raw_data_by_seq, source_seq)

              %{
                id: Ash.UUIDv7.generate(),
                event_type: event.type,
                event_id: nil,
                parent_event_id: nil,
                data: encode_data(event.data),
                raw_data: encode_data(raw_data),
                timestamp: event.timestamp,
                sequence: event.sequence,
                session_id: session_id
              }
            end)

          inserted =
            entries
            |> Enum.chunk_every(500)
            |> Enum.reduce(0, fn chunk, acc ->
              {count, _} = Repo.insert_all("events", chunk, log: false)
              acc + count
            end)

          # Update event count
          Repo.query!("UPDATE sessions SET event_count = ?1 WHERE id = ?2", [
            inserted,
            session_id
          ])

          {upd, del + deleted, ins + inserted}
        end
      end
    end
  end

  defp native_types_for(:claude), do: ~w[user assistant summary system]
  defp native_types_for(:codex), do: ~w[response_item event_msg turn_context session_meta]
  defp native_types_for(:gemini), do: ~w[gemini user assistant session_meta info error]
  defp native_types_for(:pi), do: ~w[message session model_change thinking_level_change]
  defp native_types_for(_), do: []

  defp parse_data(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp parse_data(data) when is_map(data), do: data
  defp parse_data(_), do: %{}

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_timestamp(%DateTime{} = dt), do: dt
  defp parse_timestamp(_), do: nil

  defp encode_data(data) when is_map(data), do: Jason.encode!(data)
  defp encode_data(data) when is_binary(data), do: data
  defp encode_data(data), do: inspect(data)
end
