defmodule CopilotLvWeb.Router do
  use CopilotLvWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CopilotLvWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' wss:;"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CopilotLvWeb do
    pipe_through :browser

    live "/", SessionLive.Index, :index
    live "/session/:id", SessionLive.Show, :show
    live "/sync", SyncLive.Index, :index
  end

  scope "/api", CopilotLvWeb do
    get "/sessions/:session_ref/handoff.md", SessionHandoffController, :show
  end

  # MCP endpoint for ask_user tool (called by Copilot CLI)
  # Enable LiveDashboard in development
  if Application.compile_env(:copilot_lv, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CopilotLvWeb.Telemetry
    end
  end
end
