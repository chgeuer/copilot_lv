defmodule CopilotLvWeb.SessionFileControllerTest do
  use CopilotLvWeb.ConnCase, async: false

  alias CopilotLv.Sessions.Session
  alias CopilotLvWeb.FileViewer

  @tag :tmp_dir
  test "serves a signed image within the session filesystem roots", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    session = create_session!(tmp_dir)
    on_exit(fn -> Ash.destroy!(session) end)

    image_path = Path.join([tmp_dir, "bookmarks", "images", "example.png"])
    File.mkdir_p!(Path.dirname(image_path))
    File.write!(image_path, "image bytes")
    token = FileViewer.sign_path(CopilotLvWeb.Endpoint, image_path)

    conn = get(conn, ~p"/sessions/#{session.id}/files/#{token}")

    assert response(conn, 200) == "image bytes"
    assert get_resp_header(conn, "content-type") == ["image/png"]
  end

  @tag :tmp_dir
  test "rejects signed files outside the session filesystem roots", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    session = create_session!(tmp_dir)
    on_exit(fn -> Ash.destroy!(session) end)

    outside_path = Path.join(Path.dirname(tmp_dir), "outside.png")
    File.write!(outside_path, "image bytes")
    on_exit(fn -> File.rm(outside_path) end)
    token = FileViewer.sign_path(CopilotLvWeb.Endpoint, outside_path)

    conn = get(conn, ~p"/sessions/#{session.id}/files/#{token}")

    assert response(conn, 404) == "Image not found"
  end

  defp create_session!(cwd) do
    Session
    |> Ash.Changeset.for_create(:import, %{
      id: Session.prefixed_id(:copilot, Ecto.UUID.generate()),
      cwd: cwd,
      git_root: cwd,
      source: :imported,
      status: :stopped,
      started_at: DateTime.utc_now(),
      imported_at: DateTime.utc_now(),
      event_count: 0,
      agent: :copilot
    })
    |> Ash.create!()
  end
end
