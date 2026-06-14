defmodule CopilotLv.ModelBackfill do
  @moduledoc """
  Maintenance backfill that populates `sessions.model` for sessions whose model
  column is empty.

  Some agents (notably Claude) record the model per assistant message inside the
  event payload rather than on the session row, so historically-imported
  sessions can have a `NULL` model even though their events clearly identify it.
  An empty `model` hides those sessions from the session-list model filter.

  `run/0` derives the *predominant* model for each affected session from its
  recorded events (ignoring `tool.*` echoes and the `<synthetic>` placeholder)
  and writes it back. It is idempotent — sessions that already have a model are
  left untouched — and safe to re-run.
  """

  require Logger

  @backfill_sql """
  WITH model_counts AS (
    SELECT e.session_id AS sid,
           COALESCE(json_extract(e.data, '$.model'),
                    json_extract(e.data, '$.data.model'),
                    json_extract(e.data, '$.message.model'),
                    json_extract(e.data, '$.data.message.model')) AS m,
           COUNT(*) AS c
    FROM events e
    JOIN sessions s ON s.id = e.session_id
    WHERE (s.model IS NULL OR s.model = '')
      AND e.event_type NOT LIKE 'tool.%'
    GROUP BY e.session_id, m
  ),
  best AS (
    SELECT sid, m,
           ROW_NUMBER() OVER (PARTITION BY sid ORDER BY c DESC, m ASC) AS rn
    FROM model_counts
    WHERE m IS NOT NULL AND m <> '' AND m <> '<synthetic>'
  )
  UPDATE sessions
  SET model = (SELECT m FROM best WHERE best.sid = sessions.id AND best.rn = 1)
  WHERE (sessions.model IS NULL OR sessions.model = '')
    AND EXISTS (SELECT 1 FROM best WHERE best.sid = sessions.id AND best.rn = 1)
  """

  @doc """
  Backfills `sessions.model` from event history for sessions with an empty model.

  Returns `{:ok, updated_count}` or `{:error, reason}`.
  """
  @spec run() :: {:ok, non_neg_integer()} | {:error, term()}
  def run do
    case CopilotLv.Repo.query(@backfill_sql, []) do
      {:ok, %{num_rows: updated}} ->
        Logger.info("CopilotLv.ModelBackfill: populated model for #{updated} session(s)")
        {:ok, updated}

      {:error, reason} = error ->
        Logger.error("CopilotLv.ModelBackfill failed: #{inspect(reason)}")
        error
    end
  end
end
