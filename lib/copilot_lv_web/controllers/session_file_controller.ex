defmodule CopilotLvWeb.SessionFileController do
  use CopilotLvWeb, :controller

  alias CopilotLv.SessionRegistry
  alias CopilotLvWeb.FileViewer

  @max_image_size 25_000_000

  def show(conn, %{"id" => session_id, "token" => token}) do
    with {:ok, session} <- SessionRegistry.get_session(session_id),
         {:ok, path} <- FileViewer.verify_token(CopilotLvWeb.Endpoint, token),
         true <- FileViewer.path_allowed?(path, FileViewer.allowed_bases(session)),
         {:ok, %{type: :regular, size: size}} when size <= @max_image_size <- File.stat(path),
         content_type when is_binary(content_type) <- image_content_type(path) do
      conn
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> put_resp_content_type(content_type, nil)
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "Image not found")
    end
  end

  defp image_content_type(path) do
    case MIME.from_path(path) do
      "image/" <> _ = content_type -> content_type
      _ -> nil
    end
  end
end
