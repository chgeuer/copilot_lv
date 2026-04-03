alias CopilotLv.Repo
import Ecto.Query

IO.puts("Starting copilot event ID repair...")

session_ids =
  Repo.all(
    from e in "events",
      join: s in "sessions",
      on: e.session_id == s.id,
      where: s.agent == "copilot" and is_nil(e.event_id),
      group_by: e.session_id,
      select: e.session_id
  )

base = Path.expand("~/.copilot/session-state")

repairable =
  Enum.filter(session_ids, fn prefixed ->
    pid = CopilotLv.Sessions.Session.provider_id(prefixed)
    File.exists?(Path.join([base, pid, "events.jsonl"]))
  end)

IO.puts("Found #{length(repairable)} repairable / #{length(session_ids)} total")

{total, errors} =
  Enum.reduce(repairable, {0, 0}, fn prefixed, {total, errs} ->
    pid = CopilotLv.Sessions.Session.provider_id(prefixed)
    path = Path.join([base, pid, "events.jsonl"])

    try do
      id_map =
        path
        |> File.stream!()
        |> Stream.with_index(1)
        |> Stream.map(fn {line, seq} ->
          case Jason.decode(String.trim(line)) do
            {:ok, ev} -> {seq, ev["id"], ev["parentId"]}
            _ -> nil
          end
        end)
        |> Stream.reject(&is_nil/1)
        |> Stream.filter(fn {_, id, _} -> not is_nil(id) end)
        |> Enum.to_list()

      count =
        id_map
        |> Enum.chunk_every(500)
        |> Enum.reduce(0, fn chunk, acc ->
          seqs = Enum.map(chunk, &elem(&1, 0))
          ph = Enum.map_join(1..length(seqs), ", ", fn i -> "?#{i}" end)
          ic = Enum.map_join(chunk, " ", fn {s, e, _} -> "WHEN #{s} THEN '#{String.replace(e, "'", "''")}'" end)
          pc = Enum.map_join(chunk, " ", fn {s, _, p} -> if p, do: "WHEN #{s} THEN '#{String.replace(p, "'", "''")}'" , else: "WHEN #{s} THEN NULL" end)
          sql = "UPDATE events SET event_id = CASE sequence #{ic} END, parent_event_id = CASE sequence #{pc} END WHERE session_id = ?#{length(seqs) + 1} AND sequence IN (#{ph}) AND event_id IS NULL"
          r = Repo.query!(sql, seqs ++ [prefixed], log: false)
          acc + r.num_rows
        end)

      nt = total + count
      if rem(nt, 10000) < count, do: IO.puts("  ... #{nt} events repaired")
      {nt, errs}
    rescue
      e -> IO.puts("  ERR #{prefixed}: #{Exception.message(e)}"); {total, errs + 1}
    end
  end)

IO.puts("DONE: #{total} repaired, #{errors} errors")
rem = Repo.one(from e in "events", join: s in "sessions", on: e.session_id == s.id, where: s.agent == "copilot" and is_nil(e.event_id), select: count())
IO.puts("Remaining nil: #{rem}")
