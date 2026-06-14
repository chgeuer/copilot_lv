defmodule CopilotLv.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        CopilotLvWeb.Telemetry,
        CopilotLv.Repo,
        {DNSCluster, query: Application.get_env(:copilot_lv, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: CopilotLv.PubSub},
        {Registry, keys: :unique, name: CopilotLv.SessionRegistry.Registry},
        {DynamicSupervisor, name: CopilotLv.SessionRegistry.Supervisor, strategy: :one_for_one},
        CopilotLv.AskUserBroker
      ] ++
        session_watcher_children() ++
        [
          # Start to serve requests, typically the last entry
          CopilotLvWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CopilotLv.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Initialize ETS table for Claude ask_user MCP tool context
    CopilotLv.AskUser.ClaudeTool.init_context_table()

    # Build the per-agent model catalog (curated + session-history models) after
    # the Repo is started, so the model selectors include every used model.
    CopilotLv.ModelCatalog.refresh()

    result
  end

  defp session_watcher_children do
    if Application.get_env(:copilot_lv, :start_session_watcher, true) do
      [CopilotLv.SessionWatcher]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CopilotLvWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
