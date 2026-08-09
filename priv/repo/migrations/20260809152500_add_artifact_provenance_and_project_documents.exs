defmodule CopilotLv.Repo.Migrations.AddArtifactProvenanceAndProjectDocuments do
  use Ecto.Migration

  def change do
    alter table(:session_artifacts) do
      add(:category, :text)
      add(:source_agent, :text)
      add(:source_path, :text)
      add(:mime_type, :text)
      add(:modified_at, :utc_datetime_usec)
      add(:original_size, :bigint)
      add(:stored_size, :bigint)
      add(:truncated, :boolean, default: false, null: false)
      add(:managed, :boolean, default: false, null: false)
    end

    create table(:project_documents, primary_key: false) do
      add(:id, :uuid, primary_key: true, null: false)
      add(:agent, :text, null: false)
      add(:project_key, :text, null: false)
      add(:path, :text, null: false)
      add(:source_path, :text)
      add(:content, :text)
      add(:content_hash, :text, null: false)
      add(:mime_type, :text)
      add(:modified_at, :utc_datetime_usec)
      add(:original_size, :bigint, null: false)
      add(:stored_size, :bigint, null: false)
      add(:truncated, :boolean, default: false, null: false)
    end

    create(
      unique_index(:project_documents, [:agent, :project_key, :path],
        name: "project_documents_unique_agent_project_path_index"
      )
    )
  end
end
