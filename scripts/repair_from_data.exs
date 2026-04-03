alias CopilotLv.Repo
import Ecto.Query

IO.puts("Repairing event_id from event data field for ALL agents...")

# Find events where event_id is nil but data contains an "id" field
# We can extract it from the JSON data blob
batch_size = 1000
total = Repo.one(from e in "events", where: is_nil(e.event_id), select: count())
IO.puts("Total events with nil event_id: #{total}")

# Process in batches by session
session_ids = Repo.all(from e in "events", where: is_nil(e.event_id), group_by: e.session_id, select: e.session_id)
IO.puts("Across #{length(session_ids)} sessions")

{repaired, errors} = Enum.reduce(session_ids, {0, 0}, fn sid, {rep, err} ->
  try do
    events = Repo.all(from e in "events", where: e.session_id == ^sid and is_nil(e.event_id),
      select: %{id: e.id, sequence: e.sequence, data: e.data})

    updates = Enum.reduce(events, 0, fn e, cnt ->
      data = if is_binary(e.data), do: Jason.decode!(e.data), else: e.data
      eid = is_map(data) && data["id"]
      pid = is_map(data) && data["parentId"]

      if eid do
        {n, _} = Repo.update_all(
          from(ev in "events", where: ev.id == ^e.id),
          set: [event_id: eid, parent_event_id: pid || nil]
        )
        cnt + n
      else
        cnt
      end
    end)

    new_rep = rep + updates
    if rem(new_rep, 20000) < updates and updates > 0, do: IO.puts("  ... #{new_rep} repaired")
    {new_rep, err}
  rescue
    e -> IO.puts("  ERR #{sid}: #{Exception.message(e)}"); {rep, err + 1}
  end
end)

IO.puts("DONE: #{repaired} repaired, #{errors} errors")
remaining = Repo.one(from e in "events", where: is_nil(e.event_id), select: count())
IO.puts("Remaining nil: #{remaining}")
