defmodule CopilotLvWeb.FileViewerTest do
  use ExUnit.Case, async: true

  alias CopilotLvWeb.FileViewer

  @tag :tmp_dir
  test "signs relative markdown images found below an allowed base", %{tmp_dir: tmp_dir} do
    image_path = Path.join([tmp_dir, "bookmarks", "images", "example.png"])
    File.mkdir_p!(Path.dirname(image_path))
    File.write!(image_path, "png")

    tokens =
      FileViewer.scan_and_sign(
        CopilotLvWeb.Endpoint,
        "![Example](images/example.png)",
        [tmp_dir]
      )

    assert %{"images/example.png" => %{path: ^image_path, token: token}} = tokens
    assert {:ok, ^image_path} = FileViewer.verify_token(CopilotLvWeb.Endpoint, token)
  end

  @tag :tmp_dir
  test "signs parent-relative markdown images without escaping allowed bases", %{tmp_dir: tmp_dir} do
    image_path = Path.join([tmp_dir, "bookmarks", "images", "example.png"])
    File.mkdir_p!(Path.dirname(image_path))
    File.write!(image_path, "png")

    tokens =
      FileViewer.scan_and_sign(
        CopilotLvWeb.Endpoint,
        "![Example](../images/example.png)",
        [tmp_dir]
      )

    assert %{"../images/example.png" => %{path: ^image_path, token: token}} = tokens
    assert {:ok, ^image_path} = FileViewer.verify_token(CopilotLvWeb.Endpoint, token)
  end

  @tag :tmp_dir
  test "does not resolve relative markdown images outside allowed bases", %{tmp_dir: tmp_dir} do
    outside_path = Path.join(Path.dirname(tmp_dir), "outside.png")
    File.write!(outside_path, "png")
    on_exit(fn -> File.rm(outside_path) end)

    assert FileViewer.scan_and_sign(
             CopilotLvWeb.Endpoint,
             "![Outside](../outside.png)",
             [tmp_dir]
           ) == %{}
  end

  test "limits relative image searches to workspace roots" do
    session = %{
      cwd: "/workspace/project",
      git_root: "/workspace"
    }

    assert FileViewer.relative_image_bases(session) == [
             "/workspace/project",
             "/workspace"
           ]
  end
end
