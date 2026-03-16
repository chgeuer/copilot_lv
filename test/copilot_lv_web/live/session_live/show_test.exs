defmodule CopilotLvWeb.SessionLive.ShowTest do
  use CopilotLvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CopilotLv.Repo
  alias CopilotLv.Sessions.{Checkpoint, Event, Session, SessionArtifact}

  test "renders imported checkpoints with compaction metadata and stored artifacts", %{conn: conn} do
    %{session: session, checkpoints: checkpoints, artifacts: artifacts} = create_session_fixture()

    {:ok, view, _html} = live(conn, ~p"/session/#{session.id}")

    latest_checkpoint = List.last(checkpoints)
    workspace_artifact = Enum.find(artifacts, &(&1.artifact_type == :workspace))

    assert has_element?(view, "#session-inspector")
    assert has_element?(view, "#checkpoint-tab")
    assert has_element?(view, "#artifact-tab")

    assert has_element?(view, "#checkpoint-detail", latest_checkpoint.title)
    assert has_element?(view, "#checkpoint-detail", "Second summary")
    assert has_element?(view, "#checkpoint-detail", "req-123")

    view
    |> element("#artifact-tab")
    |> render_click()

    assert has_element?(view, "#artifact-detail", "Plan")
    assert has_element?(view, "#artifact-content", "Add checkpoints inspector")

    view
    |> element("#artifact-#{workspace_artifact.id}")
    |> render_click()

    assert has_element?(view, "#artifact-detail", "workspace.yaml")
    assert has_element?(view, "#artifact-content", "summary: imported")
  end

  test "shows empty inspector states when no checkpoints or artifacts were imported", %{
    conn: conn
  } do
    %{session: session} = create_session_fixture(with_checkpoint?: false, with_artifacts?: false)

    {:ok, view, _html} = live(conn, ~p"/session/#{session.id}")

    assert has_element?(view, "#checkpoint-empty-state")
    assert has_element?(view, "#checkpoint-detail-empty")

    view
    |> element("#artifact-tab")
    |> render_click()

    assert has_element?(view, "#artifact-empty-state")
    assert has_element?(view, "#artifact-detail-empty")
  end

  test "renders a handoff copy affordance for the session", %{conn: conn} do
    %{session: session} = create_session_fixture()

    {:ok, view, _html} = live(conn, ~p"/session/#{session.id}")

    assert has_element?(view, "#handoff-command")
    assert has_element?(view, "button#copy-handoff-prompt[type=\"button\"]")
    assert has_element?(view, "button#copy-resume-cmd[type=\"button\"]")

    button_html =
      view
      |> element("#copy-handoff-prompt")
      |> render()

    assert button_html =~
             "data-handoff-url=\"http://localhost:4001/api/sessions/#{session.id}/handoff.md\""
  end

  defp create_session_fixture(opts \\ []) do
    provider_id = "test-inspector-#{System.unique_integer([:positive])}"
    session_id = Session.prefixed_id(:copilot, provider_id)

    cleanup_session!(session_id)
    on_exit(fn -> cleanup_session!(session_id) end)

    session =
      Session
      |> Ash.Changeset.for_create(:import, %{
        id: session_id,
        cwd: "/tmp/copilot-lv/session-inspector",
        model: "gpt-5.4",
        summary: "# Imported inspector session",
        title: "Imported inspector session",
        git_root: "/tmp/copilot-lv",
        branch: "main",
        copilot_version: "1.0.2",
        source: :imported,
        status: :stopped,
        started_at: DateTime.utc_now(),
        stopped_at: DateTime.utc_now(),
        imported_at: DateTime.utc_now(),
        event_count: 1,
        agent: :copilot
      })
      |> Ash.create!()

    insert_compaction_event(session.id)

    checkpoints =
      if Keyword.get(opts, :with_checkpoint?, true) do
        [
          create_checkpoint!(
            session.id,
            1,
            "First compacted context",
            "001-first-context.md",
            "<overview>First summary</overview>"
          ),
          create_checkpoint!(
            session.id,
            2,
            "Latest compacted context",
            "002-latest-context.md",
            "<overview>Second summary</overview>"
          )
        ]
      else
        []
      end

    artifacts =
      if Keyword.get(opts, :with_artifacts?, true) do
        [
          create_artifact!(
            session.id,
            "plan.md",
            :plan,
            "# Plan\n\n- Add checkpoints inspector\n"
          ),
          create_artifact!(session.id, "workspace.yaml", :workspace, "summary: imported\n"),
          create_artifact!(session.id, "files/notes.txt", :file, "artifact payload")
        ]
      else
        []
      end

    %{session: session, checkpoints: checkpoints, artifacts: artifacts}
  end

  defp create_checkpoint!(session_id, number, title, filename, content) do
    Checkpoint
    |> Ash.Changeset.for_create(:create, %{
      session_id: session_id,
      number: number,
      title: title,
      filename: filename,
      content: content
    })
    |> Ash.create!()
  end

  defp create_artifact!(session_id, path, artifact_type, content) do
    SessionArtifact
    |> Ash.Changeset.for_create(:create, %{
      session_id: session_id,
      path: path,
      content: content,
      content_hash: content_hash(content),
      size: byte_size(content),
      artifact_type: artifact_type
    })
    |> Ash.create!()
  end

  defp insert_compaction_event(session_id) do
    Event
    |> Ash.Changeset.for_create(:create, %{
      session_id: session_id,
      event_type: "session.compaction_complete",
      sequence: 1,
      timestamp: ~U[2026-03-08 15:00:00Z],
      data: %{
        "checkpointNumber" => 2,
        "checkpointPath" => "/tmp/copilot-lv/checkpoints/002-latest-context.md",
        "compactionTokensUsed" => %{
          "cachedInput" => 24_000,
          "input" => 157_329,
          "output" => 3_400
        },
        "preCompactionMessagesLength" => 42,
        "preCompactionTokens" => 134_606,
        "requestId" => "req-123",
        "success" => true,
        "summaryContent" => "<overview>Second summary</overview>"
      }
    })
    |> Ash.create!()
  end

  defp cleanup_session!(session_id) do
    for table <- ["events", "usage_entries", "checkpoints", "session_todos", "session_artifacts"] do
      Repo.query!("DELETE FROM #{table} WHERE session_id = ?1", [session_id])
    end

    case Ash.get(Session, session_id) do
      {:ok, session} -> Ash.destroy!(session)
      _ -> :ok
    end
  end

  defp content_hash(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
