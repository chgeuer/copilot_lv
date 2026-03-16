defmodule CopilotLv.Repo.Migrations.ReplaceCopilotSessionIdWithPrefixedId do
  use Ecto.Migration

  @disable_ddl_transaction true

  @fk_tables ~w(events usage_entries checkpoints session_todos session_artifacts)

  @prefix_map %{
    "copilot" => "gh",
    "claude" => "claude",
    "codex" => "codex",
    "gemini" => "gemini"
  }

  def up do
    # Use checkout to ensure PRAGMA and all updates run on the same connection
    repo().checkout(fn ->
      repo().query!("PRAGMA foreign_keys = OFF")

      for {agent, prefix} <- @prefix_map do
        update_ids_for_agent(agent, prefix)
      end

      # Handle sessions without an agent type (legacy, default to gh_)
      update_ids_for_agent(nil, "gh")

      repo().query!("PRAGMA foreign_keys = ON")
    end)

    # Drop the column outside the checkout
    alter table(:sessions) do
      remove :copilot_session_id
    end
  end

  def down do
    alter table(:sessions) do
      add :copilot_session_id, :text
    end

    for {_agent, prefix} <- @prefix_map do
      execute("""
      UPDATE sessions
      SET copilot_session_id = SUBSTR(id, #{String.length(prefix) + 2})
      WHERE id LIKE '#{prefix}_%'
      """)
    end
  end

  defp update_ids_for_agent(agent, prefix) do
    agent_filter = if agent, do: "agent = '#{agent}'", else: "agent IS NULL"

    for table <- @fk_tables do
      repo().query!("""
      UPDATE #{table} SET session_id = '#{prefix}_' || (
        SELECT s.copilot_session_id FROM sessions s WHERE s.id = #{table}.session_id
      )
      WHERE session_id IN (
        SELECT id FROM sessions WHERE #{agent_filter} AND copilot_session_id IS NOT NULL
      )
      """)
    end

    repo().query!("""
    UPDATE sessions SET id = '#{prefix}_' || copilot_session_id
    WHERE #{agent_filter} AND copilot_session_id IS NOT NULL
    """)
  end
end
