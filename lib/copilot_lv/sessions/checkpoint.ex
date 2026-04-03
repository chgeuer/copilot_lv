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

    # Structured fields from session-store.db (richer than markdown content)
    attribute(:overview, :string)
    attribute(:history, :string)
    attribute(:work_done, :string)
    attribute(:technical_details, :string)
    attribute(:important_files, :string)
    attribute(:next_steps, :string)
  end

  relationships do
    belongs_to :session, CopilotLv.Sessions.Session do
      attribute_type(:string)
      allow_nil?(false)
    end
  end

  identities do
    identity(:unique_checkpoint_per_session, [:session_id, :number])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      accept([
        :number,
        :title,
        :filename,
        :content,
        :overview,
        :history,
        :work_done,
        :technical_details,
        :important_files,
        :next_steps,
        :session_id
      ])
    end

    create :upsert do
      accept([
        :number,
        :title,
        :filename,
        :content,
        :overview,
        :history,
        :work_done,
        :technical_details,
        :important_files,
        :next_steps,
        :session_id
      ])

      upsert?(true)
      upsert_identity(:unique_checkpoint_per_session)

      upsert_fields([
        :title,
        :filename,
        :content,
        :overview,
        :history,
        :work_done,
        :technical_details,
        :important_files,
        :next_steps
      ])
    end

    read :for_session do
      argument(:session_id, :string, allow_nil?: false)
      filter(expr(session_id == ^arg(:session_id)))
      prepare(build(sort: [number: :asc]))
    end
  end
end
