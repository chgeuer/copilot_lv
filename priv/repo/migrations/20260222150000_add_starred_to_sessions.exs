defmodule CopilotLv.Repo.Migrations.AddStarredToSessions do
  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add :starred, :boolean, default: false, null: false
    end
  end

  def down do
    alter table(:sessions) do
      remove :starred
    end
  end
end
