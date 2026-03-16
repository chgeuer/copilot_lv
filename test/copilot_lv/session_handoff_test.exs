defmodule CopilotLv.SessionHandoffTest do
  use ExUnit.Case, async: false

  alias CopilotLv.SessionHandoff
  alias CopilotLv.Sessions.Session
  alias CopilotLv.Test.SessionHandoffFixtures

  test "renders markdown handoff with transcript, operations, todos, and checkpoints" do
    %{session: session} = SessionHandoffFixtures.create_copilot_handoff_session()
    on_exit(fn -> SessionHandoffFixtures.cleanup_session!(session.id) end)

    {:ok, %{session: resolved_session, markdown: markdown}} = SessionHandoff.generate(session.id)

    assert resolved_session.id == session.id
    assert markdown =~ "<!-- copilot-lv-session-handoff:v1 -->"
    assert markdown =~ "# Session Handoff"
    assert markdown =~ "## Files Read"
    assert markdown =~ "Read `/tmp/copilot-lv/project/lib/example.ex:300-500`"
    refute markdown =~ "defmodule Example do"
    assert markdown =~ "## Files Written"
    assert markdown =~ "Created file `lib/session_handoff.ex`"
    assert markdown =~ "Updated `lib/example.ex`"
    assert markdown =~ "## Commands Executed"
    assert markdown =~ "git commit -m \"Add session handoff export\""
    assert markdown =~ "mix test test/example_test.exs"
    refute markdown =~ "2 files changed"
    assert markdown =~ "## Searches"
    assert markdown =~ "SessionHandoff"
    assert markdown =~ "## Todos"
    assert markdown =~ "Add handoff UI button"
    assert markdown =~ "## Checkpoints"
    assert markdown =~ "Checkpoint after wiring endpoint"
    assert markdown =~ "## Conversation Transcript"
    assert markdown =~ "Investigate the failing tests and add a session handoff endpoint."
    assert markdown =~ "### Commit Message 1"
    assert markdown =~ "Add session handoff export"
    assert markdown =~ "Implemented the handoff endpoint and validated the focused test run."
  end

  test "resolves a raw provider id when the agent is supplied" do
    %{session: session} = SessionHandoffFixtures.create_copilot_handoff_session()
    on_exit(fn -> SessionHandoffFixtures.cleanup_session!(session.id) end)

    provider_id = Session.provider_id(session.id)

    {:ok, %{session: resolved_session}} = SessionHandoff.generate(provider_id, agent: :copilot)

    assert resolved_session.id == session.id
  end
end
