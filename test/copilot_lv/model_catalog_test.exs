defmodule CopilotLv.ModelCatalogTest do
  use ExUnit.Case, async: false

  alias CopilotLv.{ModelCatalog, SessionStoreImpl}

  test "reloads session models after a session write invalidates the cache" do
    model = "gpt-99.7-sol"
    session = session_fixture(:copilot, model)

    ModelCatalog.refresh()
    refute model_id?(ModelCatalog.for_agent(:copilot), model)

    assert {:ok, _} = SessionStoreImpl.upsert_session(session)
    on_exit(fn -> SessionStoreImpl.delete_session(session.id) end)

    assert model_id?(ModelCatalog.for_agent(:copilot), model)
  end

  test "reloads per-event models after an event write invalidates the cache" do
    model = "claude-sonnet-99-7"
    session = session_fixture(:claude, nil)

    assert {:ok, _} = SessionStoreImpl.upsert_session(session)
    on_exit(fn -> SessionStoreImpl.delete_session(session.id) end)

    ModelCatalog.refresh()
    refute model_id?(ModelCatalog.for_agent(:claude), model)

    event = %{
      type: "assistant.message",
      data: %{"model" => model},
      timestamp: DateTime.utc_now(),
      sequence: 1
    }

    assert {:ok, 1} = SessionStoreImpl.insert_events(session.id, [event])
    assert model_id?(ModelCatalog.for_agent(:claude), model)
  end

  defp session_fixture(agent, model) do
    provider_id = Ash.UUID.generate()

    %JidoSessions.Session{
      id: CopilotLv.Sessions.Session.prefixed_id(agent, provider_id),
      agent: agent,
      source: :imported,
      status: :stopped,
      cwd: "/tmp/model-catalog-test",
      model: model,
      started_at: DateTime.utc_now()
    }
  end

  defp model_id?(models, id), do: Enum.any?(models, &(elem(&1, 1) == id))
end
