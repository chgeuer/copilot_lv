defmodule CopilotLvWeb.SessionDigestController do
  use CopilotLvWeb, :controller

  alias CopilotLv.Sessions.Digest

  def show(conn, %{"id" => session_id} = params) do
    opts = [
      include_reasoning: truthy_param?(params["reasoning"], true),
      include_checkpoints: truthy_param?(params["checkpoints"], true),
      include_plan: truthy_param?(params["plan"], true),
      include_file_artifacts: truthy_param?(params["files"], true)
    ]

    case Digest.generate(session_id, opts) do
      {:ok, markdown} ->
        filename = "digest-#{session_id}.md"

        conn
        |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("text/markdown", "utf-8")
        |> send_resp(200, markdown)

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("text/plain", "utf-8")
        |> send_resp(404, "Session not found")
    end
  end

  defp truthy_param?(nil, default), do: default
  defp truthy_param?(value, _default), do: value in [true, "true", "1", 1]
end
