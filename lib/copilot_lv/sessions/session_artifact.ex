defmodule CopilotLv.Sessions.SessionArtifact do
  use Ash.Resource,
    domain: CopilotLv.Sessions,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("session_artifacts")
    repo(CopilotLv.Repo)
  end

  attributes do
    uuid_v7_primary_key(:id)

    attribute(:path, :string, allow_nil?: false)
    attribute(:content, :string)
    attribute(:content_hash, :string, allow_nil?: false)
    attribute(:size, :integer, default: 0)

    attribute(:artifact_type, :atom,
      constraints: [one_of: [:plan, :workspace, :file, :session_db_dump, :codex_thread_meta]],
      allow_nil?: false
    )
  end

  relationships do
    belongs_to :session, CopilotLv.Sessions.Session do
      attribute_type(:string)
      allow_nil?(false)
    end
  end

  identities do
    identity(:unique_path_per_session, [:session_id, :path])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:path, :content, :content_hash, :size, :artifact_type, :session_id])
    end

    create :upsert do
      accept([:path, :content, :content_hash, :size, :artifact_type, :session_id])
      upsert?(true)
      upsert_identity(:unique_path_per_session)
      upsert_fields([:content, :content_hash, :size])
    end

    read :for_session do
      argument(:session_id, :string, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id)))
      prepare(build(sort: [path: :asc]))
    end

    read :by_type do
      argument(:artifact_type, :atom, allow_nil?: false)
      filter(expr(artifact_type == ^arg(:artifact_type)))
    end
  end
end
