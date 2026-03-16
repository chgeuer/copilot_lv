defmodule CopilotLv.Test.SessionHandoffFixtures do
  alias CopilotLv.Repo
  alias CopilotLv.Sessions.{Checkpoint, Event, Session, SessionTodo}

  def create_copilot_handoff_session do
    provider_id = "handoff-#{System.unique_integer([:positive])}"
    session_id = Session.prefixed_id(:copilot, provider_id)

    cleanup_session!(session_id)

    session =
      Session
      |> Ash.Changeset.for_create(:import, %{
        id: session_id,
        cwd: "/tmp/copilot-lv/project",
        model: "gpt-5.4",
        summary: "# Implement session handoff",
        title: "Implement session handoff",
        git_root: "/tmp/copilot-lv/project",
        branch: "main",
        source: :imported,
        status: :stopped,
        started_at: ~U[2026-03-08 20:00:00Z],
        stopped_at: ~U[2026-03-08 20:30:00Z],
        imported_at: DateTime.utc_now(),
        event_count: 13,
        agent: :copilot,
        hostname: "framework"
      })
      |> Ash.create!()

    events = [
      {1, "user.message",
       %{"content" => "Investigate the failing tests and add a session handoff endpoint."}},
      {2, "assistant.message",
       %{"content" => "I'll inspect the relevant files and wire up a handoff endpoint."}},
      {3, "tool.execution_start",
       %{
         "toolName" => "view",
         "toolCallId" => "tool-1",
         "arguments" => %{
           "path" => "/tmp/copilot-lv/project/lib/example.ex",
           "view_range" => [300, 500]
         }
       }},
      {4, "tool.execution_complete",
       %{
         "toolCallId" => "tool-1",
         "success" => true,
         "result" => %{"content" => "defmodule Example do\nend\n"}
       }},
      {5, "tool.execution_start",
       %{
         "toolName" => "rg",
         "toolCallId" => "tool-2",
         "arguments" => %{"pattern" => "SessionHandoff", "path" => "/tmp/copilot-lv/project/lib"}
       }},
      {6, "tool.execution_complete",
       %{
         "toolCallId" => "tool-2",
         "success" => true,
         "result" => %{"content" => "lib/example.ex:12:defmodule SessionHandoff"}
       }},
      {7, "tool.execution_start",
       %{
         "toolName" => "apply_patch",
         "toolCallId" => "tool-3",
         "arguments" =>
           "*** Begin Patch\n*** Update File: lib/example.ex\n@@\n-def old\n+def new\n*** Add File: lib/session_handoff.ex\n+defmodule SessionHandoff do\n+end\n*** End Patch\n"
       }},
      {8, "tool.execution_complete",
       %{
         "toolCallId" => "tool-3",
         "success" => true,
         "result" => %{"content" => "Patch applied successfully"}
       }},
      {9, "tool.execution_start",
       %{
         "toolName" => "bash",
         "toolCallId" => "tool-4",
         "arguments" => %{
           "command" =>
             "git add lib/example.ex lib/session_handoff.ex && git commit -m \"Add session handoff export\"",
           "description" => "Create handoff commit"
         }
       }},
      {10, "tool.execution_complete",
       %{
         "toolCallId" => "tool-4",
         "success" => true,
         "result" => %{
           "content" =>
             "Exit code: 0\nWall time: 0.2 seconds\nOutput:\n[main abc1234] Add session handoff export\n 2 files changed, 42 insertions(+)\n"
         }
       }},
      {11, "tool.execution_start",
       %{
         "toolName" => "bash",
         "toolCallId" => "tool-5",
         "arguments" => %{
           "command" => "mix test test/example_test.exs",
           "description" => "Run focused tests"
         }
       }},
      {12, "tool.execution_complete",
       %{
         "toolCallId" => "tool-5",
         "success" => true,
         "result" => %{
           "content" => "Exit code: 0\nWall time: 0.2 seconds\nOutput:\n1 test, 0 failures\n"
         }
       }},
      {13, "assistant.message",
       %{"content" => "Implemented the handoff endpoint and validated the focused test run."}}
    ]

    Enum.each(events, fn {sequence, event_type, data} ->
      Event
      |> Ash.Changeset.for_create(:create, %{
        session_id: session.id,
        event_type: event_type,
        sequence: sequence,
        timestamp: DateTime.add(session.started_at, sequence, :second),
        data: data
      })
      |> Ash.create!()
    end)

    Checkpoint
    |> Ash.Changeset.for_create(:create, %{
      session_id: session.id,
      number: 1,
      title: "Checkpoint after wiring endpoint",
      filename: "001-handoff.md",
      content: "Endpoint and rendering service added"
    })
    |> Ash.create!()

    SessionTodo
    |> Ash.Changeset.for_create(:create, %{
      session_id: session.id,
      todo_id: "ship-handoff-ui",
      title: "Add handoff UI button",
      description: "Expose a copy-to-clipboard prompt on the session page.",
      status: "pending",
      depends_on: ["ship-handoff-endpoint"]
    })
    |> Ash.create!()

    SessionTodo
    |> Ash.Changeset.for_create(:create, %{
      session_id: session.id,
      todo_id: "ship-handoff-endpoint",
      title: "Add handoff endpoint",
      description: "Serve markdown handoff documents over HTTP.",
      status: "done",
      depends_on: []
    })
    |> Ash.create!()

    %{session: session}
  end

  def cleanup_session!(session_id) do
    for table <- ["events", "usage_entries", "checkpoints", "session_todos", "session_artifacts"] do
      Repo.query!("DELETE FROM #{table} WHERE session_id = ?1", [session_id])
    end

    case Ash.get(Session, session_id) do
      {:ok, session} -> Ash.destroy!(session)
      _ -> :ok
    end
  end
end
