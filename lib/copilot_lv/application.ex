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

    # Register session-history models after Repo is started
    register_session_models()

    result
  end

  defp session_watcher_children do
    if Application.get_env(:copilot_lv, :start_session_watcher, true) do
      [CopilotLv.SessionWatcher]
    else
      []
    end
  end

  defp register_session_models do
    model_ids =
      CopilotLv.Sessions.Session
      |> Ash.read!()
      |> Enum.map(& &1.model)

    Jido.GHCopilot.Models.register_session_models(model_ids)
  rescue
    _ -> :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CopilotLvWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
