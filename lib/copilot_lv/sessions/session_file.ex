defmodule CopilotLv.Sessions.SessionFile do
  use Ash.Resource,
    domain: CopilotLv.Sessions,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("session_files")
    repo(CopilotLv.Repo)
  end

  attributes do
    uuid_v7_primary_key(:id)
    attribute(:file_path, :string, allow_nil?: false)
    attribute(:tool_name, :string)
    attribute(:turn_index, :integer)
    attribute(:first_seen_at, :string)
  end

  relationships do
    belongs_to :session, CopilotLv.Sessions.Session do
      attribute_type(:string)
      allow_nil?(false)
    end
  end

  identities do
    identity(:unique_file_per_session, [:session_id, :file_path])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:file_path, :tool_name, :turn_index, :first_seen_at, :session_id])
    end

    create :upsert do
      accept([:file_path, :tool_name, :turn_index, :first_seen_at, :session_id])
      upsert?(true)
      upsert_identity(:unique_file_per_session)
      upsert_fields([:tool_name, :turn_index])
    end

    read :for_session do
      argument(:session_id, :string, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id)))
      prepare(build(sort: [file_path: :asc]))
    end
  end
end
