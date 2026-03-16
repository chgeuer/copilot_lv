defmodule CopilotLvWeb.SyncLive.Index do
  use CopilotLvWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    sources = load_sync_sources()
    stats = load_stats()

    socket =
      socket
      |> assign(:sources, sources)
      |> assign(:stats, stats)
      |> assign(:syncing_source, nil)
      |> assign(:new_host, "")
      |> assign(:add_host_open, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("sync_local", %{"agent" => agent_str}, socket) do
    agent = String.to_existing_atom(agent_str)
    pid = self()
    source_key = "local:#{agent_str}"

    Task.start(fn ->
      stats = CopilotLv.AgentDiscovery.import_local(agent, verbose: true)
      send(pid, {:source_sync_complete, source_key, stats})
    end)

    {:noreply, assign(socket, :syncing_source, source_key)}
  end

  def handle_event("sync_local_all", _params, socket) do
    pid = self()

    Task.start(fn ->
      copilot_result = CopilotLv.Sync.run()

      agent_stats =
        [:claude, :codex, :gemini]
        |> Enum.map(&CopilotLv.AgentDiscovery.import_local(&1, []))
        |> Enum.reduce(%{imported: 0, repaired: 0, skipped: 0, errors: 0}, fn s, acc ->
          %{
            imported: acc.imported + s.imported,
            repaired: acc.repaired + s.repaired,
            skipped: acc.skipped + s.skipped,
            errors: acc.errors + s.errors
          }
        end)

      copilot_imported =
        case copilot_result do
          {:ok, s} -> s.imported + s.updated
          _ -> 0
        end

      total = %{
        agent_stats
        | imported: agent_stats.imported + copilot_imported
      }

      send(pid, {:source_sync_complete, "local:all", total})
    end)

    {:noreply, assign(socket, :syncing_source, "local:all")}
  end

  def handle_event("sync_remote", %{"host" => host}, socket) do
    pid = self()
    source_key = "remote:#{host}"

    Task.start(fn ->
      stats =
        CopilotLv.AgentDiscovery.import_remote(host, :all, verbose: true)

      send(pid, {:source_sync_complete, source_key, stats})
    end)

    {:noreply, assign(socket, :syncing_source, source_key)}
  end

  def handle_event("toggle_add_host", _params, socket) do
    {:noreply, update(socket, :add_host_open, &(!&1))}
  end

  def handle_event("add_host", %{"host" => host}, socket) do
    host = String.trim(host)

    if host != "" do
      save_remote_host(host)

      {:noreply,
       socket
       |> assign(:sources, load_sync_sources())
       |> assign(:add_host_open, false)
       |> assign(:new_host, "")
       |> put_flash(:info, "Added remote host: #{host}")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_host", %{"host" => host}, socket) do
    remove_remote_host(host)

    {:noreply,
     socket
     |> assign(:sources, load_sync_sources())
     |> put_flash(:info, "Removed host: #{host}")}
  end

  @impl true
  def handle_info({:source_sync_complete, source_key, stats}, socket) do
    total = stats.imported + stats.repaired

    msg =
      cond do
        total > 0 && stats.repaired > 0 ->
          "#{source_key}: #{stats.imported} imported, #{stats.repaired} repaired"

        total > 0 ->
          "#{source_key}: #{stats.imported} imported"

        true ->
          "#{source_key}: up to date"
      end

    {:noreply,
     socket
     |> assign(:syncing_source, nil)
     |> assign(:stats, load_stats())
     |> put_flash(:info, msg)}
  end

  # ── Data ──

  defp load_sync_sources do
    local_agents = detect_local_agents()
    remote_hosts = load_remote_hosts()
    {local_agents, remote_hosts}
  end

  defp detect_local_agents do
    Enum.map(CopilotLv.Agents.all(), fn mod ->
      dirs = mod.well_known_dirs()
      present = Enum.any?(dirs, &File.dir?/1)

      session_count =
        if present, do: length(CopilotLv.Agents.discover_local(mod.agent_type())), else: 0

      %{
        agent: mod.agent_type(),
        present: present,
        dirs: dirs,
        session_count: session_count
      }
    end)
  end

  defp load_stats do
    sessions = CopilotLv.Sessions.Session |> Ash.read!()
    by_host = Enum.group_by(sessions, & &1.hostname)
    by_agent = Enum.group_by(sessions, & &1.agent)

    %{
      total: length(sessions),
      by_host: Map.new(by_host, fn {k, v} -> {k, length(v)} end),
      by_agent: Map.new(by_agent, fn {k, v} -> {k, length(v)} end)
    }
  end

  @hosts_file Path.join(System.user_home!(), ".config/copilot_lv/remote_hosts.json")

  defp load_remote_hosts do
    case File.read(@hosts_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, hosts} when is_list(hosts) -> hosts
          _ -> []
        end

      _ ->
        # Auto-detect from SSH config
        detect_ssh_hosts()
    end
  end

  defp detect_ssh_hosts do
    ssh_config = Path.expand("~/.ssh/config")

    if File.exists?(ssh_config) do
      ssh_config
      |> File.read!()
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^\s*Host\s+(.+)$/i, String.trim(line)) do
          [_, hosts] ->
            hosts
            |> String.split()
            |> Enum.reject(&String.contains?(&1, "*"))
            |> Enum.reject(&(&1 in ["*", "localhost"]))

          _ ->
            []
        end
      end)
      |> Enum.uniq()
    else
      []
    end
  end

  defp save_remote_host(host) do
    hosts = load_remote_hosts()

    unless host in hosts do
      dir = Path.dirname(@hosts_file)
      File.mkdir_p!(dir)
      File.write!(@hosts_file, Jason.encode!(Enum.uniq([host | hosts]), pretty: true))
    end
  end

  defp remove_remote_host(host) do
    hosts = load_remote_hosts() |> Enum.reject(&(&1 == host))
    dir = Path.dirname(@hosts_file)
    File.mkdir_p!(dir)
    File.write!(@hosts_file, Jason.encode!(hosts, pretty: true))
  end

  defp agent_icon(:copilot), do: "🤖"
  defp agent_icon(:claude), do: "🟠"
  defp agent_icon(:codex), do: "🔵"
  defp agent_icon(:gemini), do: "🟢"
  defp agent_icon(_), do: "⚙️"

  # ── Render ──

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200 p-6">
      <div class="max-w-3xl mx-auto space-y-6">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-3">
            <.link navigate={~p"/"} class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-left" class="size-4" /> Back
            </.link>
            <h1 class="text-2xl font-bold">Sync Settings</h1>
          </div>
          <div class="text-sm text-base-content/50">
            {@stats.total} total sessions
          </div>
        </div>

        <%!-- Local Sources --%>
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body">
            <div class="flex items-center justify-between mb-4">
              <h2 class="card-title text-lg">Local Agents</h2>
              <button
                phx-click="sync_local_all"
                class="btn btn-sm btn-primary gap-2"
                disabled={@syncing_source != nil}
              >
                <%= if @syncing_source == "local:all" do %>
                  <span class="loading loading-spinner loading-xs"></span> Syncing...
                <% else %>
                  🔄 Sync All Local
                <% end %>
              </button>
            </div>

            <div class="space-y-2">
              <% {local_agents, _remote_hosts} = @sources %>
              <%= for agent <- local_agents do %>
                <div class="flex items-center justify-between p-3 rounded-lg bg-base-200/50">
                  <div class="flex items-center gap-3">
                    <span class="text-xl">{agent_icon(agent.agent)}</span>
                    <div>
                      <div class="font-medium">{agent.agent}</div>
                      <div class="text-xs text-base-content/50">
                        <%= if agent.present do %>
                          {agent.session_count} sessions on disk
                          · {Map.get(@stats.by_agent, agent.agent, 0)} in DB
                        <% else %>
                          <span class="text-base-content/30">not installed</span>
                        <% end %>
                      </div>
                    </div>
                  </div>
                  <%= if agent.present do %>
                    <button
                      phx-click="sync_local"
                      phx-value-agent={agent.agent}
                      class="btn btn-sm btn-outline btn-xs"
                      disabled={@syncing_source != nil}
                    >
                      <%= if @syncing_source == "local:#{agent.agent}" do %>
                        <span class="loading loading-spinner loading-xs"></span>
                      <% else %>
                        Sync
                      <% end %>
                    </button>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Remote Hosts --%>
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body">
            <div class="flex items-center justify-between mb-4">
              <h2 class="card-title text-lg">Remote Hosts</h2>
              <button
                phx-click="toggle_add_host"
                class="btn btn-sm btn-outline gap-1"
              >
                <.icon name="hero-plus" class="size-3" /> Add Host
              </button>
            </div>

            <%= if @add_host_open do %>
              <.form for={%{}} phx-submit="add_host" class="flex gap-2 mb-4">
                <input
                  type="text"
                  name="host"
                  value={@new_host}
                  placeholder="hostname (from ~/.ssh/config)"
                  class="input input-bordered input-sm flex-1"
                  autofocus
                />
                <button type="submit" class="btn btn-sm btn-primary">Add</button>
                <button type="button" phx-click="toggle_add_host" class="btn btn-sm btn-ghost">
                  Cancel
                </button>
              </.form>
            <% end %>

            <div class="space-y-2">
              <% {_local_agents, remote_hosts} = @sources %>
              <%= if remote_hosts == [] do %>
                <div class="text-center text-base-content/40 py-4 text-sm">
                  No remote hosts configured.
                  Hosts from ~/.ssh/config will appear automatically.
                </div>
              <% end %>
              <%= for host <- remote_hosts do %>
                <div class="flex items-center justify-between p-3 rounded-lg bg-base-200/50">
                  <div class="flex items-center gap-3">
                    <span class="text-xl">🖥</span>
                    <div>
                      <div class="font-medium">{host}</div>
                      <div class="text-xs text-base-content/50">
                        {Map.get(@stats.by_host, host, 0)} sessions in DB
                      </div>
                    </div>
                  </div>
                  <div class="flex items-center gap-2">
                    <button
                      phx-click="sync_remote"
                      phx-value-host={host}
                      class="btn btn-sm btn-outline btn-xs"
                      disabled={@syncing_source != nil}
                    >
                      <%= if @syncing_source == "remote:#{host}" do %>
                        <span class="loading loading-spinner loading-xs"></span> Syncing...
                      <% else %>
                        Sync
                      <% end %>
                    </button>
                    <button
                      phx-click="remove_host"
                      phx-value-host={host}
                      class="btn btn-xs btn-ghost text-error"
                      data-confirm={"Remove #{host}?"}
                    >
                      <.icon name="hero-x-mark" class="size-3" />
                    </button>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Stats Overview --%>
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body">
            <h2 class="card-title text-lg mb-3">Database Overview</h2>
            <div class="grid grid-cols-2 gap-4">
              <div>
                <div class="text-xs text-base-content/50 uppercase tracking-wider mb-2">By Agent</div>
                <div class="space-y-1">
                  <%= for {agent, count} <- Enum.sort(@stats.by_agent) do %>
                    <div class="flex justify-between text-sm">
                      <span class="flex items-center gap-2">
                        <span>{agent_icon(agent)}</span>
                        <span>{agent}</span>
                      </span>
                      <span class="font-mono text-base-content/60">{count}</span>
                    </div>
                  <% end %>
                </div>
              </div>
              <div>
                <div class="text-xs text-base-content/50 uppercase tracking-wider mb-2">By Host</div>
                <div class="space-y-1">
                  <%= for {host, count} <- Enum.sort(@stats.by_host) do %>
                    <div class="flex justify-between text-sm">
                      <span>{host || "(local)"}</span>
                      <span class="font-mono text-base-content/60">{count}</span>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
