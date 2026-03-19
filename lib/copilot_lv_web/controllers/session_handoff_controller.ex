defmodule CopilotLvWeb.SessionHandoffController do
  use CopilotLvWeb, :controller

  def show(conn, %{"session_ref" => session_ref} = params) do
    opts = [
      agent: params["agent"],
      full_transcript: truthy_param?(params["full_transcript"]),
      max_command_output_chars: parse_integer(params["max_command_output_chars"], 4_000),
      max_assistant_chars: parse_integer(params["max_assistant_chars"], 12_000),
      relative_to: params["relative_to"]
    ]

    case JidoSessions.Handoff.generate(CopilotLv.SessionStoreImpl, nil, session_ref, opts) do
      {:ok, %{session: session, markdown: markdown}} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("x-copilotlv-session-id", session.id)
        |> put_resp_header("x-copilotlv-agent", Atom.to_string(session.agent))
        |> put_resp_content_type("text/markdown", "utf-8")
        |> send_resp(200, markdown)

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("text/plain", "utf-8")
        |> send_resp(404, "Session not found")

      {:error, {:ambiguous, ids}} ->
        conn
        |> put_resp_content_type("text/plain", "utf-8")
        |> send_resp(409, "Ambiguous session reference. Matches: #{Enum.join(ids, ", ")}")
    end
  end

  defp truthy_param?(value), do: value in [true, "true", "1", 1]

  defp parse_integer(nil, default), do: default

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      :error -> default
    end
  end

  defp parse_integer(value, _default) when is_integer(value), do: value
  defp parse_integer(_value, default), do: default
end
