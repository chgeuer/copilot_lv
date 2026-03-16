defmodule CopilotLv.Sessions.SessionTodo do
  use Ash.Resource,
    domain: CopilotLv.Sessions,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("session_todos")
    repo(CopilotLv.Repo)
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:todo_id, :string, allow_nil?: false)
    attribute(:title, :string, allow_nil?: false)
    attribute(:description, :string)

    attribute(:status, :string,
      constraints: [match: ~r/^(pending|in_progress|done|blocked)$/],
      default: "pending"
    )

    attribute(:depends_on, {:array, :string}, default: [])
  end

  relationships do
    belongs_to :session, CopilotLv.Sessions.Session do
      attribute_type(:string)
      allow_nil?(false)
    end
  end

  identities do
    identity(:unique_todo_per_session, [:session_id, :todo_id])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:todo_id, :title, :description, :status, :depends_on, :session_id])
    end

    create :upsert do
      accept([:todo_id, :title, :description, :status, :depends_on, :session_id])
      upsert?(true)
      upsert_identity(:unique_todo_per_session)
      upsert_fields([:title, :description, :status, :depends_on])
    end

    read :for_session do
      argument(:session_id, :string, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id)))
      prepare(build(sort: [todo_id: :asc]))
    end
  end
end
