defmodule CopilotLv.Sessions.Checkpoint do
  use Ash.Resource,
    domain: CopilotLv.Sessions,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("checkpoints")
    repo(CopilotLv.Repo)
  end

  attributes do
    uuid_v7_primary_key(:id)
    attribute(:number, :integer, allow_nil?: false)
    attribute(:title, :string)
    attribute(:filename, :string)
    attribute(:content, :string)
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
      accept([:number, :title, :filename, :content, :session_id])
    end

    read :for_session do
      argument(:session_id, :string, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id)))
      prepare(build(sort: [number: :asc]))
    end
  end
end
