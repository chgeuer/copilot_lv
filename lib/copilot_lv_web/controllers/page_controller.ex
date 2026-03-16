defmodule CopilotLvWeb.PageController do
  use CopilotLvWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
