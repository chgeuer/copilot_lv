defmodule CopilotLv.Sessions.Event do
  use Ash.Resource,
    domain: CopilotLv.Sessions,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("events")
    repo(CopilotLv.Repo)
  end

  attributes do
    uuid_v7_primary_key(:id)
    attribute(:event_type, :string, allow_nil?: false)
    attribute(:event_id, :string)
    attribute(:parent_event_id, :string)
    attribute(:data, :map, default: %{})
    attribute(:timestamp, :utc_datetime_usec, default: &DateTime.utc_now/0)
    attribute(:sequence, :integer, allow_nil?: false)
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
        :event_type,
        :event_id,
        :parent_event_id,
        :data,
        :timestamp,
        :sequence,
        :session_id
      ])
    end

    read :for_session do
      argument(:session_id, :string, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id)))
      prepare(build(sort: [sequence: :asc]))
    end
  end
end
