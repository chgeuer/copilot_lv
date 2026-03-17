defmodule CopilotLvWeb.SessionLive.Index do
  use CopilotLvWeb, :live_view

  import CopilotLvWeb.DirTreePicker
  import CopilotLvWeb.FsBrowserPicker
  alias CopilotLv.SessionRegistry

  require Ash.Query

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(5000, :refresh_active)
    end

    models =
      Jido.GHCopilot.Models.all()
      |> Enum.map(fn {name, id, multiplier} -> {name, id, multiplier} end)
      |> Enum.sort_by(fn {name, _id, _multiplier} -> String.downcase(name) end)

    active_sessions = load_active_sessions()
    {filter_dirs, filter_models, filter_hosts, filter_agents} = load_filter_options()

    socket =
      socket
      |> assign(:models, models)
      |> assign(:active_sessions, active_sessions)
      |> assign(
        :form,
        to_form(%{"cwd" => File.cwd!(), "model" => "claude-opus-4.6", "agent" => "copilot"},
          as: :session
        )
      )
      |> assign(:selected_agent, :copilot)
      |> assign(:creating, false)
      |> assign(:syncing, false)
      |> assign(:sync_result, nil)
      # Search / filter state
      |> assign(:search, "")
      |> assign(:filter_model, "")
      |> assign(:filter_dir, "")
      |> assign(:filter_host, "")
      |> assign(:filter_agent, "")
      |> assign(:page, 1)
      |> assign(:filter_dirs, filter_dirs)
      |> assign(:filter_models, filter_models)
      |> assign(:filter_hosts, filter_hosts)
      |> assign(:filter_agents, filter_agents)
      |> assign(:dir_picker_open, false)
      |> assign(:dir_picker_collapsed, MapSet.new())
      |> assign(:dir_picker_filter, "")
      |> assign(:fs_picker_open, false)
      |> assign(:fs_expanded_dirs, %{})
      |> assign_filtered_sessions()

    {:ok, socket}
  end

  # ── Events ──

  @impl true
  def handle_event("select_agent", %{"agent" => agent_str}, socket) do
    agent = String.to_existing_atom(agent_str)
    {:noreply, assign(socket, :selected_agent, agent)}
  end

  def handle_event("create_session", %{"session" => params}, socket) do
    cwd = params["cwd"] |> String.trim()
    agent = params["agent"] || "copilot"
    model = params["model"]
    model = if model == "", do: nil, else: model

    if File.dir?(cwd) do
      if agent != "copilot" do
        {:noreply,
         put_flash(
           socket,
           :info,
           "Live #{agent} sessions coming soon. Use the CLI: #{agent_cli_hint(agent, cwd)}"
         )}
      else
        socket = assign(socket, :creating, true)

        case SessionRegistry.create_session(cwd: cwd, model: model) do
          {:ok, id} ->
            {:noreply, push_navigate(socket, to: ~p"/session/#{id}")}

          {:error, reason} ->
            socket =
              socket
              |> assign(:creating, false)
              |> put_flash(:error, "Failed to create session: #{inspect(reason)}")

            {:noreply, socket}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "Directory does not exist: #{cwd}")}
    end
  end

  def handle_event("stop_session", %{"id" => id}, socket) do
    SessionRegistry.stop_session(id)

    {:noreply,
     socket
     |> assign(:active_sessions, load_active_sessions())
     |> assign_filtered_sessions()}
  end

  def handle_event("sync_sessions", _params, socket) do
    pid = self()

    Task.start(fn ->
      # Sync Copilot sessions (original sync)
      copilot_result = CopilotLv.Sync.run()

      # Sync all other agents locally
      agent_stats =
        [:claude, :codex, :gemini, :pi]
        |> Enum.map(&CopilotLv.AgentDiscovery.import_local(&1, []))
        |> Enum.reduce(%{imported: 0, repaired: 0, skipped: 0, errors: 0}, fn s, acc ->
          %{
            imported: acc.imported + s.imported,
            repaired: acc.repaired + s.repaired,
            skipped: acc.skipped + s.skipped,
            errors: acc.errors + s.errors
          }
        end)

      send(pid, {:sync_complete, copilot_result, agent_stats})
    end)

    {:noreply, assign(socket, :syncing, true)}
  end

  def handle_event("search", %{"value" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search, query)
     |> assign(:page, 1)
     |> assign_filtered_sessions()}
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:filter_model, params["model"] || socket.assigns.filter_model)
     |> assign(:filter_dir, params["dir"] || socket.assigns.filter_dir)
     |> assign(:filter_host, params["host"] || socket.assigns.filter_host)
     |> assign(:filter_agent, params["agent"] || socket.assigns.filter_agent)
     |> assign(:page, 1)
     |> assign_filtered_sessions()}
  end

  def handle_event("toggle_dir_picker", _params, socket) do
    {:noreply, update(socket, :dir_picker_open, &(!&1))}
  end

  def handle_event("close_dir_picker", _params, socket) do
    {:noreply, assign(socket, dir_picker_open: false, dir_picker_filter: "")}
  end

  def handle_event("dir_picker_toggle_node", %{"path" => path}, socket) do
    collapsed = socket.assigns.dir_picker_collapsed

    collapsed =
      if MapSet.member?(collapsed, path),
        do: MapSet.delete(collapsed, path),
        else: MapSet.put(collapsed, path)

    {:noreply, assign(socket, :dir_picker_collapsed, collapsed)}
  end

  def handle_event("dir_picker_filter", %{"value" => value}, socket) do
    {:noreply, assign(socket, :dir_picker_filter, value)}
  end

  def handle_event("select_dir", %{"dir" => dir}, socket) do
    {:noreply,
     socket
     |> assign(:filter_dir, dir)
     |> assign(:dir_picker_open, false)
     |> assign(:dir_picker_filter, "")
     |> assign(:page, 1)
     |> assign_filtered_sessions()}
  end

  def handle_event("fs_picker_toggle", _params, socket) do
    {:noreply, update(socket, :fs_picker_open, &(!&1))}
  end

  def handle_event("fs_picker_close", _params, socket) do
    {:noreply, assign(socket, :fs_picker_open, false)}
  end

  def handle_event("fs_picker_toggle_dir", %{"path" => path}, socket) do
    expanded = socket.assigns.fs_expanded_dirs

    expanded =
      if Map.has_key?(expanded, path) do
        Map.delete(expanded, path)
      else
        Map.put(expanded, path, true)
      end

    {:noreply, assign(socket, :fs_expanded_dirs, expanded)}
  end

  def handle_event("fs_picker_select", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(
       :form,
       to_form(%{"cwd" => path, "model" => socket.assigns.form[:model].value}, as: :session)
     )
     |> assign(:fs_picker_open, false)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:search, "")
     |> assign(:filter_model, "")
     |> assign(:filter_dir, "")
     |> assign(:filter_host, "")
     |> assign(:filter_agent, "")
     |> assign(:page, 1)
     |> assign_filtered_sessions()}
  end

  def handle_event("load_more", _params, socket) do
    {:noreply,
     socket
     |> update(:page, &(&1 + 1))
     |> assign_filtered_sessions()}
  end

  def handle_event("delete_session", %{"id" => id}, socket) do
    case SessionRegistry.delete_session(id) do
      :ok ->
        {filter_dirs, filter_models, filter_hosts, filter_agents} = load_filter_options()

        {:noreply,
         socket
         |> put_flash(:info, "Session deleted")
         |> assign(:active_sessions, load_active_sessions())
         |> assign(:filter_dirs, filter_dirs)
         |> assign(:filter_models, filter_models)
         |> assign(:filter_hosts, filter_hosts)
         |> assign(:filter_agents, filter_agents)
         |> assign_filtered_sessions()}

      {:error, :starred} ->
        {:noreply, put_flash(socket, :error, "Unstar the session before deleting")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Session not found")}
    end
  end

  def handle_event("toggle_star", %{"id" => id}, socket) do
    SessionRegistry.toggle_star(id)
    {:noreply, assign_filtered_sessions(socket)}
  end

  @impl true
  def handle_info(:refresh_active, socket) do
    {:noreply, assign(socket, :active_sessions, load_active_sessions())}
  end

  def handle_info({:sync_complete, copilot_result, agent_stats}, socket) do
    {filter_dirs, filter_models, filter_hosts, filter_agents} = load_filter_options()

    socket =
      case copilot_result do
        {:ok, stats} ->
          total_new = stats.imported + stats.updated + agent_stats.imported
          total_repaired = agent_stats.repaired

          msg =
            cond do
              total_new > 0 && total_repaired > 0 ->
                "Synced: #{total_new} new, #{total_repaired} repaired"

              total_new > 0 ->
                "Synced: #{total_new} new sessions"

              total_repaired > 0 ->
                "Repaired #{total_repaired} sessions"

              true ->
                "All sessions up to date"
            end

          socket
          |> put_flash(:info, msg)
          |> assign(:sync_result, stats)

        {:error, msg} ->
          if agent_stats.imported > 0 || agent_stats.repaired > 0 do
            socket
            |> put_flash(
              :info,
              "Agents: #{agent_stats.imported} new, #{agent_stats.repaired} repaired"
            )
            |> put_flash(:error, "Copilot sync failed: #{msg}")
          else
            put_flash(socket, :error, "Sync failed: #{msg}")
          end
      end

    {:noreply,
     socket
     |> assign(:syncing, false)
     |> assign(:active_sessions, load_active_sessions())
     |> assign(:filter_dirs, filter_dirs)
     |> assign(:filter_models, filter_models)
     |> assign(:filter_hosts, filter_hosts)
     |> assign(:filter_agents, filter_agents)
     |> assign_filtered_sessions()}
  end

  # ── Data Loading ──

  defp load_active_sessions do
    SessionRegistry.list_all_sessions()
    |> Enum.filter(fn session -> SessionRegistry.session_exists?(session.id) end)
    |> Enum.map(fn session ->
      live_status =
        try do
          info = CopilotLv.SessionServer.get_state(session.id)
          info.status
        rescue
          _ -> session.status
        catch
          :exit, _ -> session.status
        end

      %{
        id: session.id,
        cwd: session.cwd,
        model: session.model,
        title: session.title,
        status: live_status,
        started_at: session.started_at
      }
    end)
  end

  defp load_filter_options do
    sessions =
      CopilotLv.Sessions.Session
      |> Ash.Query.for_read(:list_all)
      |> Ash.read!()

    dirs =
      sessions
      |> Enum.map(& &1.cwd)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_dir, count} -> -count end)
      |> Enum.map(fn {dir, count} ->
        short = shorten_path(dir)
        {"#{short} (#{count})", dir}
      end)

    models =
      sessions
      |> Enum.map(& &1.model)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_model, count} -> -count end)
      |> Enum.map(fn {model, count} -> {"#{model} (#{count})", model} end)

    hosts =
      sessions
      |> Enum.map(& &1.hostname)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_host, count} -> -count end)
      |> Enum.map(fn {host, count} -> {"#{host} (#{count})", host} end)

    agents =
      sessions
      |> Enum.map(&to_string(&1.agent))
      |> Enum.reject(&(&1 == ""))
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_agent, count} -> -count end)
      |> Enum.map(fn {agent, count} -> {"#{agent} (#{count})", agent} end)

    {dirs, models, hosts, agents}
  end

  defp assign_filtered_sessions(socket) do
    search = socket.assigns.search
    filter_model = socket.assigns.filter_model
    filter_dir = socket.assigns.filter_dir
    filter_host = socket.assigns.filter_host
    filter_agent = socket.assigns.filter_agent
    page = socket.assigns.page

    query =
      CopilotLv.Sessions.Session
      |> Ash.Query.for_read(:list_all)
      |> Ash.Query.filter(status == :stopped)

    query =
      if filter_model != "" do
        Ash.Query.filter(query, model: filter_model)
      else
        query
      end

    query =
      if filter_dir != "" do
        Ash.Query.filter(query, cwd: filter_dir)
      else
        query
      end

    query =
      if filter_host != "" do
        Ash.Query.filter(query, hostname: filter_host)
      else
        query
      end

    query =
      if filter_agent != "" do
        Ash.Query.filter(query, agent: filter_agent)
      else
        query
      end

    all_results = Ash.read!(query)

    # Text search across title, summary, cwd, branch
    filtered =
      if search != "" do
        term = String.downcase(search)

        Enum.filter(all_results, fn s ->
          matches?(s.title, term) ||
            matches?(s.summary, term) ||
            matches?(s.cwd, term) ||
            matches?(s.branch, term) ||
            matches?(s.model, term)
        end)
      else
        all_results
      end

    total = length(filtered)
    visible = Enum.take(filtered, page * @per_page)
    has_more = total > length(visible)

    socket
    |> assign(:sessions, visible)
    |> assign(:total_count, total)
    |> assign(:has_more, has_more)
  end

  defp matches?(nil, _term), do: false
  defp matches?(str, term), do: String.contains?(String.downcase(str), term)

  defp agent_badge_class(:claude), do: "badge-warning"
  defp agent_badge_class(:codex), do: "badge-info"
  defp agent_badge_class(:gemini), do: "badge-success"
  defp agent_badge_class(:pi), do: "badge-secondary"
  defp agent_badge_class(_), do: "badge-ghost"

  defp agent_cli_hint("claude", cwd), do: "cd #{cwd} && claude"
  defp agent_cli_hint("codex", cwd), do: "cd #{cwd} && codex"
  defp agent_cli_hint("gemini", cwd), do: "cd #{cwd} && gemini"
  defp agent_cli_hint("pi", cwd), do: "cd #{cwd} && pi"
  defp agent_cli_hint(_, cwd), do: "cd #{cwd}"

  defp shorten_path(path) do
    home = System.user_home!()

    if String.starts_with?(path, home) do
      "~" <> String.trim_leading(path, home)
    else
      path
    end
  end

  # ── Render ──

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200 p-6">
      <div class="max-w-5xl mx-auto space-y-6">
        <div class="flex items-center justify-between">
          <h1 class="text-3xl font-bold">Copilot Sessions</h1>
          <div class="flex items-center gap-2">
            <button phx-click="sync_sessions" class="btn btn-sm btn-outline gap-2" disabled={@syncing}>
              <%= if @syncing do %>
                <span class="loading loading-spinner loading-xs"></span> Syncing...
              <% else %>
                🔄 Sync
              <% end %>
            </button>
            <.link navigate={~p"/sync"} class="btn btn-sm btn-ghost" title="Sync settings">
              <.icon name="hero-cog-6-tooth" class="size-4" />
            </.link>
          </div>
        </div>

        <%!-- New Session Form --%>
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body py-4">
            <.form for={@form} phx-submit="create_session" class="flex flex-col gap-3">
              <%!-- Agent selector --%>
              <div class="flex items-center gap-2">
                <span class="text-xs text-base-content/50">Agent:</span>
                <div class="flex gap-1">
                  <%= for {agent, icon, label} <- [
                    {"copilot", "🤖", "Copilot"},
                    {"claude", "🟠", "Claude"},
                    {"codex", "🔵", "Codex"},
                    {"gemini", "🟢", "Gemini"},
                    {"pi", "🟣", "Pi"}
                  ] do %>
                    <button
                      type="button"
                      phx-click="select_agent"
                      phx-value-agent={agent}
                      class={[
                        "btn btn-xs gap-1 transition-all",
                        if(to_string(@selected_agent) == agent,
                          do: "btn-primary",
                          else: "btn-ghost"
                        )
                      ]}
                    >
                      <span>{icon}</span>
                      <span>{label}</span>
                      <%= unless agent == "copilot" do %>
                        <span class="badge badge-xs badge-ghost opacity-60">CLI</span>
                      <% end %>
                    </button>
                  <% end %>
                </div>
              </div>

              <input type="hidden" name="session[agent]" value={@selected_agent} />

              <%!-- CWD + model + start --%>
              <div class="flex items-end gap-3">
                <.fs_browser_picker
                  current_path={@form[:cwd].value}
                  open={@fs_picker_open}
                  expanded_dirs={@fs_expanded_dirs}
                />
                <%= if @selected_agent == :copilot do %>
                  <div class="form-control w-52">
                    <label class="label py-1"><span class="label-text text-xs">Model</span></label>
                    <select name="session[model]" class="select select-bordered select-sm w-full">
                      <option value="">Auto</option>
                      <%= for {name, id, multiplier} <- @models do %>
                        <option value={id} selected={id == @form[:model].value}>
                          {name} ({format_cost(multiplier)})
                        </option>
                      <% end %>
                    </select>
                  </div>
                <% end %>
                <button type="submit" class="btn btn-primary btn-sm" disabled={@creating}>
                  <%= if @creating do %>
                    <span class="loading loading-spinner loading-xs"></span>
                  <% else %>
                    Start
                  <% end %>
                </button>
              </div>
            </.form>
          </div>
        </div>

        <%!-- Active Sessions --%>
        <%= if @active_sessions != [] do %>
          <div class="card bg-base-100 shadow-lg border-l-4 border-success">
            <div class="card-body py-3">
              <h2 class="text-sm font-semibold text-success uppercase tracking-wider">
                Active Sessions
              </h2>
              <div class="space-y-1">
                <%= for session <- @active_sessions do %>
                  <div class="flex items-center justify-between p-2 rounded-lg hover:bg-base-200 transition-colors group">
                    <.link
                      navigate={~p"/session/#{session.id}"}
                      class="flex items-center gap-3 min-w-0 flex-1 cursor-pointer"
                    >
                      <div class={"badge badge-sm #{status_badge(session.status)}"}>
                        {session.status}
                      </div>
                      <div class="min-w-0">
                        <div class="font-medium text-sm truncate">
                          {session.title || shorten_path(session.cwd)}
                        </div>
                        <div class="text-xs text-base-content/50">
                          {session.model || "auto"} · {relative_time(session.started_at)}
                        </div>
                      </div>
                    </.link>
                    <div class="flex gap-2 items-center">
                      <button
                        phx-click="stop_session"
                        phx-value-id={session.id}
                        class="btn btn-xs btn-error btn-outline opacity-0 group-hover:opacity-100 transition-opacity"
                      >
                        Stop
                      </button>
                      <.link
                        navigate={~p"/session/#{session.id}"}
                        class="text-xs text-base-content/40"
                      >
                        →
                      </.link>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Search & Filter --%>
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body py-3">
            <div class="flex flex-wrap items-end gap-3">
              <div class="form-control flex-1 min-w-[200px]">
                <input
                  type="text"
                  name="search"
                  value={@search}
                  phx-keyup="search"
                  phx-debounce="200"
                  class="input input-bordered input-sm w-full"
                  placeholder="Search sessions by title, content, directory..."
                />
              </div>
              <.form for={%{}} phx-change="filter" class="flex flex-wrap gap-2">
                <select name="host" class="select select-bordered select-sm">
                  <option value="">All hosts</option>
                  <%= for {label, value} <- @filter_hosts do %>
                    <option value={value} selected={@filter_host == value}>{label}</option>
                  <% end %>
                </select>
                <select name="agent" class="select select-bordered select-sm">
                  <option value="">All agents</option>
                  <%= for {label, value} <- @filter_agents do %>
                    <option value={value} selected={@filter_agent == value}>{label}</option>
                  <% end %>
                </select>
              </.form>
              <.dir_tree_picker
                dirs={@filter_dirs}
                selected={@filter_dir}
                open={@dir_picker_open}
                collapsed={@dir_picker_collapsed}
                filter={@dir_picker_filter}
              />
              <.form for={%{}} phx-change="filter" class="flex gap-2">
                <select name="model" class="select select-bordered select-sm">
                  <option value="">All models</option>
                  <%= for {label, value} <- @filter_models do %>
                    <option value={value} selected={@filter_model == value}>{label}</option>
                  <% end %>
                </select>
              </.form>
              <%= if @search != "" || @filter_model != "" || @filter_dir != "" || @filter_host != "" || @filter_agent != "" do %>
                <button phx-click="clear_filters" class="btn btn-ghost btn-sm">✕ Clear</button>
              <% end %>
            </div>
            <div class="text-xs text-base-content/50 mt-1">
              {if @search != "" || @filter_model != "" || @filter_dir != "" || @filter_host != "" ||
                    @filter_agent != "",
                  do: "#{@total_count} matching",
                  else: "#{@total_count} total"} sessions
            </div>
          </div>
        </div>

        <%!-- Session List --%>
        <div class="space-y-1">
          <%= for session <- @sessions do %>
            <div class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow group">
              <div class="card-body py-3 px-4">
                <div class="flex items-start justify-between gap-4">
                  <div class="flex items-center gap-2 min-w-0 flex-1">
                    <button
                      phx-click="toggle_star"
                      phx-value-id={session.id}
                      class={[
                        "text-lg flex-none transition-colors",
                        if(session.starred,
                          do: "text-amber-400 hover:text-amber-300",
                          else: "text-base-content/20 hover:text-amber-400"
                        )
                      ]}
                      title={if session.starred, do: "Unstar", else: "Star"}
                    >
                      <%= if session.starred do %>
                        ★
                      <% else %>
                        ☆
                      <% end %>
                    </button>
                    <.link navigate={~p"/session/#{session.id}"} class="min-w-0 flex-1 cursor-pointer">
                      <div class="font-medium text-sm truncate">
                        {session.title || "Untitled session"}
                      </div>
                      <div class="flex flex-wrap items-center gap-x-3 gap-y-0.5 mt-0.5 text-xs text-base-content/50">
                        <%= if session.agent && session.agent != :copilot do %>
                          <span class={[
                            "badge badge-xs font-medium",
                            agent_badge_class(session.agent)
                          ]}>
                            {session.agent}
                          </span>
                        <% end %>
                        <%= if session.hostname do %>
                          <span class="font-mono text-base-content/40">🖥 {session.hostname}</span>
                        <% end %>
                        <span class="font-mono">{shorten_path(session.cwd)}</span>
                        <%= if session.model do %>
                          <span class="badge badge-ghost badge-xs">{session.model}</span>
                        <% end %>
                        <%= if session.branch do %>
                          <span>⎇ {session.branch}</span>
                        <% end %>
                        <%= if session.event_count && session.event_count > 0 do %>
                          <span>{session.event_count} events</span>
                        <% end %>
                      </div>
                    </.link>
                  </div>
                  <div class="flex items-center gap-2">
                    <%= unless session.starred do %>
                      <button
                        phx-click="delete_session"
                        phx-value-id={session.id}
                        data-confirm="Delete this session? This removes it from the database and disk permanently."
                        class="btn btn-xs btn-error btn-outline opacity-0 group-hover:opacity-100 transition-opacity"
                      >
                        Delete
                      </button>
                    <% end %>
                    <div class="text-xs text-base-content/40 whitespace-nowrap">
                      {format_date(session.started_at)}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Load More --%>
        <%= if @has_more do %>
          <div class="text-center">
            <button phx-click="load_more" class="btn btn-ghost btn-sm">
              Load more sessions...
            </button>
          </div>
        <% end %>

        <%= if @sessions == [] and (@search != "" or @filter_model != "" or @filter_dir != "") do %>
          <div class="text-center text-base-content/50 py-8">
            No sessions match your filters.
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Helpers ──

  defp status_badge(:idle), do: "badge-success"
  defp status_badge(:thinking), do: "badge-warning"
  defp status_badge(:tool_running), do: "badge-info"
  defp status_badge(:starting), do: "badge-neutral"
  defp status_badge(_), do: "badge-ghost"

  defp format_cost(0), do: "free"
  defp format_cost(m) when m < 1, do: "#{m}x"
  defp format_cost(m), do: "#{m}x"

  defp format_date(nil), do: ""

  defp format_date(dt) do
    today = Date.utc_today()
    date = DateTime.to_date(dt)

    cond do
      date == today -> Calendar.strftime(dt, "Today %H:%M")
      date == Date.add(today, -1) -> Calendar.strftime(dt, "Yesterday %H:%M")
      Date.diff(today, date) < 7 -> Calendar.strftime(dt, "%a %H:%M")
      date.year == today.year -> Calendar.strftime(dt, "%b %d")
      true -> Calendar.strftime(dt, "%b %d, %Y")
    end
  end

  defp relative_time(nil), do: ""

  defp relative_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end
end
