defmodule CopilotLv.ArtifactScannerTest do
  use ExUnit.Case, async: false

  alias CopilotLv.{ArtifactScanner, SessionStoreImpl}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "copilot-lv-artifact-scanner-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "recursively imports significant text while pruning generated trees", %{root: root} do
    write!(root, "plan.md", "# Plan")
    write!(root, "files/reports/finding.md", "# Finding")
    write!(root, "files/reports/change.diff", "diff --git a/a b/a")
    write!(root, "files/node_modules/package/README.md", "dependency documentation")
    write!(root, "files/image.txt", <<0, 1, 2, 3>>)
    write!(root, "files/data.json", ~s({"not":"selected"}))

    report = ArtifactScanner.scan_session(:copilot, "session-id", root)
    paths = Enum.map(report.artifacts, & &1.path)

    assert paths == ["files/reports/change.diff", "files/reports/finding.md", "plan.md"]
    assert report.excluded.binary == 1
    assert report.excluded.unsupported_extension == 1
    refute Enum.any?(paths, &String.contains?(&1, "node_modules"))
  end

  test "stores a bounded head and tail preview for oversized text", %{root: root} do
    content = :binary.copy("abcdefghij", div(ArtifactScanner.max_content_bytes(), 10) + 2)
    write!(root, "files/large.txt", content)

    artifact =
      ArtifactScanner.scan_session(:copilot, "session-id", root).artifacts
      |> List.first()

    assert artifact.truncated
    assert artifact.original_size == byte_size(content)
    assert artifact.stored_size < artifact.original_size
    assert artifact.content =~ "content truncated"
    assert artifact.content_hash == sha256(content)
  end

  test "maps Gemini tool output to its owning session", %{root: root} do
    chat = write!(root, "chats/session-2026-01-01T00-00-abcd1234.json", "{}")

    write!(
      root,
      "tool-outputs/session-abcd1234-full/run_shell_command.txt",
      "important output"
    )

    report = ArtifactScanner.scan_session(:gemini, "abcd1234-full", chat)

    assert [%{path: path, category: :tool_output}] = report.artifacts
    assert path =~ "run_shell_command.txt"
  end

  test "scans Claude memory as project documents", %{root: root} do
    jsonl = write!(root, "session-id.jsonl", "{}")
    write!(root, "memory/MEMORY.md", "# Durable project memory")

    report = ArtifactScanner.scan_project_documents(:claude, "/project", jsonl)

    assert [%{path: "memory/MEMORY.md", category: :project_memory, project_key: "/project"}] =
             report.artifacts
  end

  test "reconciliation removes managed artifacts absent from a later manifest", %{root: root} do
    session_id = "gh_artifact-scanner-#{System.unique_integer([:positive])}"

    session = %JidoSessions.Session{
      id: session_id,
      agent: :copilot,
      source: :imported,
      status: :stopped,
      cwd: root,
      started_at: DateTime.utc_now()
    }

    assert {:ok, _} = SessionStoreImpl.upsert_session(session)
    on_exit(fn -> SessionStoreImpl.delete_session(session_id) end)

    path = write!(root, "files/report.md", "# Report")
    first = ArtifactScanner.scan_session(:copilot, session_id, root)

    assert %{stored: 1, removed: 0} =
             SessionStoreImpl.reconcile_artifacts(session_id, :copilot, first.artifacts)

    File.rm!(path)
    second = ArtifactScanner.scan_session(:copilot, session_id, root)

    assert %{stored: 0, removed: 1} =
             SessionStoreImpl.reconcile_artifacts(session_id, :copilot, second.artifacts)

    assert SessionStoreImpl.get_artifacts(session_id) == []
  end

  defp write!(root, relative_path, content) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
