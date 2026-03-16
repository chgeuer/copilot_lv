defmodule CopilotLv.Repo.Migrations.AddMultiAgentFields do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :hostname, :string
      add :agent, :string
      add :config_dir, :string
    end

    # Backfill existing sessions as copilot agent with local hostname
    execute(
      "UPDATE sessions SET agent = 'copilot' WHERE agent IS NULL",
      "UPDATE sessions SET agent = NULL WHERE agent = 'copilot'"
    )
  end
end
