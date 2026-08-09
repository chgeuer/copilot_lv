defmodule CopilotLv.Sessions.ProjectDocument do
  use Ash.Resource,
    domain: CopilotLv.Sessions,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("project_documents")
    repo(CopilotLv.Repo)
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:agent, :atom,
      allow_nil?: false,
      constraints: [one_of: [:copilot, :claude, :codex, :gemini, :pi]]
    )

    attribute(:project_key, :string, allow_nil?: false)
    attribute(:path, :string, allow_nil?: false)
    attribute(:source_path, :string)
    attribute(:content, :string)
    attribute(:content_hash, :string, allow_nil?: false)
    attribute(:mime_type, :string)
    attribute(:modified_at, :utc_datetime_usec)
    attribute(:original_size, :integer, allow_nil?: false)
    attribute(:stored_size, :integer, allow_nil?: false)
    attribute(:truncated, :boolean, default: false)
  end

  identities do
    identity(:unique_agent_project_path, [:agent, :project_key, :path])
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      primary?(true)

      accept([
        :agent,
        :project_key,
        :path,
        :source_path,
        :content,
        :content_hash,
        :mime_type,
        :modified_at,
        :original_size,
        :stored_size,
        :truncated
      ])

      upsert?(true)
      upsert_identity(:unique_agent_project_path)

      upsert_fields([
        :source_path,
        :content,
        :content_hash,
        :mime_type,
        :modified_at,
        :original_size,
        :stored_size,
        :truncated
      ])
    end

    read :for_project do
      argument(:agent, :atom, allow_nil?: false)
      argument(:project_key, :string, allow_nil?: false)
      filter(expr(agent == ^arg(:agent) and project_key == ^arg(:project_key)))
      prepare(build(sort: [path: :asc]))
    end
  end
end
