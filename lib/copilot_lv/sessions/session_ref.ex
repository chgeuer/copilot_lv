defmodule CopilotLv.Sessions.SessionRef do
  use Ash.Resource,
    domain: CopilotLv.Sessions,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("session_refs")
    repo(CopilotLv.Repo)
  end

  attributes do
    uuid_v7_primary_key(:id)
    attribute(:ref_type, :string, allow_nil?: false)
    attribute(:ref_value, :string, allow_nil?: false)
    attribute(:turn_index, :integer)
    attribute(:created_at, :string)
  end

  relationships do
    belongs_to :session, CopilotLv.Sessions.Session do
      attribute_type(:string)
      allow_nil?(false)
    end
  end

  identities do
    identity(:unique_ref_per_session, [:session_id, :ref_type, :ref_value])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:ref_type, :ref_value, :turn_index, :created_at, :session_id])
    end

    create :upsert do
      accept([:ref_type, :ref_value, :turn_index, :created_at, :session_id])
      upsert?(true)
      upsert_identity(:unique_ref_per_session)
      upsert_fields([:turn_index])
    end

    read :for_session do
      argument(:session_id, :string, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id)))
      prepare(build(sort: [ref_type: :asc, ref_value: :asc]))
    end
  end
end
