defmodule CopilotLv.Sessions.UsageEntry do
  use Ash.Resource,
    domain: CopilotLv.Sessions,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("usage_entries")
    repo(CopilotLv.Repo)
  end

  attributes do
    uuid_v7_primary_key(:id)
    attribute(:model, :string)
    attribute(:input_tokens, :integer, default: 0)
    attribute(:output_tokens, :integer, default: 0)
    attribute(:cache_read_tokens, :integer, default: 0)
    attribute(:cache_write_tokens, :integer, default: 0)
    attribute(:cost, :float)
    attribute(:initiator, :string)
    attribute(:duration_ms, :integer)
    attribute(:timestamp, :utc_datetime_usec, default: &DateTime.utc_now/0)
  end

  relationships do
    belongs_to :session, CopilotLv.Sessions.Session do
      attribute_type(:string)
      allow_nil?(false)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      accept([
        :model,
        :input_tokens,
        :output_tokens,
        :cache_read_tokens,
        :cache_write_tokens,
        :cost,
        :initiator,
        :duration_ms,
        :timestamp,
        :session_id
      ])
    end

    read :for_session do
      argument(:session_id, :string, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id)))
      prepare(build(sort: [timestamp: :asc]))
    end
  end
end
