defmodule CopilotLvWeb.SessionHandoffControllerTest do
  use CopilotLvWeb.ConnCase, async: false

  alias CopilotLv.Test.SessionHandoffFixtures

  test "GET /api/sessions/:session_ref/handoff.md renders markdown", %{conn: conn} do
    %{session: session} = SessionHandoffFixtures.create_copilot_handoff_session()
    on_exit(fn -> SessionHandoffFixtures.cleanup_session!(session.id) end)

    conn = get(conn, ~p"/api/sessions/#{session.id}/handoff.md")

    assert response(conn, 200) =~ "# Session Handoff"
    assert get_resp_header(conn, "content-type") == ["text/markdown; charset=utf-8"]
    assert get_resp_header(conn, "x-copilotlv-session-id") == [session.id]
    assert get_resp_header(conn, "x-copilotlv-agent") == ["copilot"]
  end
end
