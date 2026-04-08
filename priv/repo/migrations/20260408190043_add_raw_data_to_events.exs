defmodule CopilotLv.Repo.Migrations.AddRawDataToEvents do
  use Ecto.Migration

  def change do
    alter table(:events) do
      add :raw_data, :text
    end
  end
end
