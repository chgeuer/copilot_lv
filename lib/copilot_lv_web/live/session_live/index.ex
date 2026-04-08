defmodule CopilotLvWeb.SessionLive.Index do
  use CopilotLvWeb, :live_view

  import CopilotLvWeb.DirTreePicker
  import CopilotLvWeb.FsBrowserPicker
  alias CopilotLv.SessionRegistry
  alias CopilotLv.AgentPermissions

  require Ash.Query

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(5000, :refresh_active)
    end

    models =
      CopilotLvWeb.SessionLive.Show.models_for_agent(:copilot)
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
      |> assign(:confirm_delete_id, nil)
      |> assign(:permissions_modal, nil)
      |> assign(:selected_ids, MapSet.new())
      |> assign(:confirm_delete_selected, false)
      |> assign_filtered_sessions()

    {:ok, socket}
  end

  # ── Events ──

  @impl true
  def handle_event("select_agent", %{"agent" => agent_str}, socket) do
    agent = String.to_existing_atom(agent_str)

    models =
      CopilotLvWeb.SessionLive.Show.models_for_agent(agent)
      |> Enum.sort_by(fn {name, _id, _multiplier} -> String.downcase(name) end)

    {:noreply, socket |> assign(:selected_agent, agent) |> assign(:models, models)}
  end

  def handle_event("create_session", %{"session" => params}, socket) do
    cwd = params["cwd"] |> String.trim()
    agent = params["agent"] || "copilot"
    agent_atom = String.to_existing_atom(agent)
    model = params["model"]
    model = if model == "", do: nil, else: model

    if File.dir?(cwd) do
      modal = %{
        agent: agent_atom,
        cwd: cwd,
        model: model,
        permissions: AgentPermissions.defaults(agent_atom),
        options: AgentPermissions.options(agent_atom)
      }

      {:noreply, assign(socket, :permissions_modal, modal)}
    else
      {:noreply, put_flash(socket, :error, "Directory does not exist: #{cwd}")}
    end
  end

  def handle_event("close_permissions_modal", _params, socket) do
    {:noreply, assign(socket, :permissions_modal, nil)}
  end

  def handle_event("update_permission", %{"key" => key, "value" => value}, socket) do
    modal = socket.assigns.permissions_modal
    updated_perms = Map.put(modal.permissions, key, value)
    {:noreply, assign(socket, :permissions_modal, %{modal | permissions: updated_perms})}
  end

  def handle_event("toggle_permission", %{"key" => key}, socket) do
    modal = socket.assigns.permissions_modal
    current = modal.permissions[key]
    new_val = if current == "true" or current == true, do: "false", else: "true"
    updated_perms = Map.put(modal.permissions, key, new_val)
    {:noreply, assign(socket, :permissions_modal, %{modal | permissions: updated_perms})}
  end

  def handle_event("confirm_create_session", _params, socket) do
    modal = socket.assigns.permissions_modal
    permissions = AgentPermissions.from_params(modal.agent, modal.permissions)

    socket = socket |> assign(:creating, true) |> assign(:permissions_modal, nil)

    case SessionRegistry.create_session(
           cwd: modal.cwd,
           model: modal.model,
           agent: modal.agent,
           permissions: permissions
         ) do
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

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirm_delete_id, id)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_id, nil)}
  end

  def handle_event("delete_session", %{"id" => id}, socket) do
    case SessionRegistry.delete_session(id) do
      :ok ->
        {filter_dirs, filter_models, filter_hosts, filter_agents} = load_filter_options()

        {:noreply,
         socket
         |> put_flash(:info, "Session deleted")
         |> assign(:confirm_delete_id, nil)
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

  def handle_event("toggle_select", %{"id" => id} = params, socket) do
    ctrl = params["ctrl"] == "true"
    selected = socket.assigns.selected_ids

    selected =
      cond do
        ctrl && MapSet.member?(selected, id) ->
          MapSet.delete(selected, id)

        ctrl ->
          MapSet.put(selected, id)

        MapSet.member?(selected, id) && MapSet.size(selected) == 1 ->
          MapSet.new()

        true ->
          MapSet.new([id])
      end

    {:noreply,
     socket
     |> assign(:selected_ids, selected)
     |> assign(:confirm_delete_selected, false)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_ids, MapSet.new())
     |> assign(:confirm_delete_selected, false)}
  end

  def handle_event("confirm_delete_selected", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_selected, true)}
  end

  def handle_event("cancel_delete_selected", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_selected, false)}
  end

  def handle_event("delete_selected", _params, socket) do
    selected = socket.assigns.selected_ids

    {ok_count, err_count} =
      Enum.reduce(selected, {0, 0}, fn id, {ok, err} ->
        case SessionRegistry.delete_session(id) do
          :ok -> {ok + 1, err}
          _ -> {ok, err + 1}
        end
      end)

    {filter_dirs, filter_models, filter_hosts, filter_agents} = load_filter_options()

    flash =
      case {ok_count, err_count} do
        {n, 0} -> {:info, "Deleted #{n} session#{if n > 1, do: "s", else: ""}"}
        {0, n} -> {:error, "Failed to delete #{n} session#{if n > 1, do: "s", else: ""}"}
        {n, m} -> {:info, "Deleted #{n}, failed #{m}"}
      end

    {:noreply,
     socket
     |> put_flash(elem(flash, 0), elem(flash, 1))
     |> assign(:selected_ids, MapSet.new())
     |> assign(:confirm_delete_selected, false)
     |> assign(:confirm_delete_id, nil)
     |> assign(:active_sessions, load_active_sessions())
     |> assign(:filter_dirs, filter_dirs)
     |> assign(:filter_models, filter_models)
     |> assign(:filter_hosts, filter_hosts)
     |> assign(:filter_agents, filter_agents)
     |> assign_filtered_sessions()}
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
      |> Ash.Query.filter(status == :stopped)
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

  defp agent_icon(:copilot), do: "🤖"
  defp agent_icon(:claude), do: "🟠"
  defp agent_icon(:codex), do: "🔵"
  defp agent_icon(:gemini), do: "🟢"
  defp agent_icon(:pi), do: "🟣"
  defp agent_icon(_), do: "🤖"

  defp agent_label(:copilot), do: "Copilot"
  defp agent_label(:claude), do: "Claude"
  defp agent_label(:codex), do: "Codex"
  defp agent_label(:gemini), do: "Gemini"
  defp agent_label(:pi), do: "Pi"
  defp agent_label(_), do: "Agent"

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
      <div class="max-w-7xl mx-auto space-y-6">
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
                <%= if @selected_agent != :pi do %>
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

        <%!-- Bulk Action Bar --%>
        <%= if MapSet.size(@selected_ids) > 0 do %>
          <div class="alert shadow-lg flex items-center justify-between">
            <div class="flex items-center gap-2">
              <span class="font-medium">
                {MapSet.size(@selected_ids)} session{if MapSet.size(@selected_ids) > 1, do: "s", else: ""} selected
              </span>
            </div>
            <div class="flex items-center gap-2">
              <%= if @confirm_delete_selected do %>
                <span class="text-sm text-error font-medium">Delete all selected?</span>
                <button phx-click="delete_selected" class="btn btn-sm btn-error">
                  Yes, delete
                </button>
                <button phx-click="cancel_delete_selected" class="btn btn-sm btn-ghost">
                  No
                </button>
              <% else %>
                <button phx-click="confirm_delete_selected" class="btn btn-sm btn-error btn-outline">
                  🗑 Delete selected
                </button>
              <% end %>
              <button phx-click="clear_selection" class="btn btn-sm btn-ghost">
                ✕ Clear
              </button>
            </div>
          </div>
        <% end %>

        <%!-- Session List --%>
        <div class="card bg-base-100 shadow-sm overflow-x-auto">
          <table class="table table-sm table-zebra w-full">
            <thead>
              <tr class="text-xs text-base-content/60 uppercase tracking-wider">
                <th class="w-8">★</th>
                <th>Title</th>
                <th>Host</th>
                <th>Directory</th>
                <th class="text-right">Events</th>
                <th class="text-right">Last Activity</th>
                <th class="w-16"></th>
              </tr>
            </thead>
            <tbody id="session-list" phx-hook="CtrlClick">
              <%= for session <- @sessions do %>
                <tr
                  id={"session-row-#{session.id}"}
                  data-select-id={session.id}
                  class={[
                    "group cursor-pointer transition-colors",
                    if(MapSet.member?(@selected_ids, session.id),
                      do: "!bg-primary/10 outline outline-1 outline-primary/30",
                      else: "hover"
                    )
                  ]}
                >
                  <td class="align-middle">
                    <button
                      phx-click="toggle_star"
                      phx-value-id={session.id}
                      class={[
                        "text-lg transition-colors",
                        if(session.starred,
                          do: "text-amber-400 hover:text-amber-300",
                          else: "text-base-content/20 hover:text-amber-400"
                        )
                      ]}
                      title={if session.starred, do: "Unstar", else: "Star"}
                    >
                      {if session.starred, do: "★", else: "☆"}
                    </button>
                  </td>
                  <td class="align-middle max-w-xs">
                    <.link navigate={~p"/session/#{session.id}"} class="cursor-pointer">
                      <div class="font-medium text-sm truncate">
                        {session.title || "Untitled session"}
                      </div>
                      <%= if session.agent && session.agent != :copilot do %>
                        <span class={[
                          "badge badge-xs font-medium",
                          agent_badge_class(session.agent)
                        ]}>
                          {session.agent}
                        </span>
                      <% end %>
                    </.link>
                  </td>
                  <td class="align-middle text-xs text-base-content/50 font-mono whitespace-nowrap">
                    <%= if session.hostname do %>
                      {session.hostname}
                    <% end %>
                  </td>
                  <td class="align-middle max-w-[200px]">
                    <.link navigate={~p"/session/#{session.id}"} class="cursor-pointer">
                      <span class="text-xs font-mono truncate block" title={session.cwd}>
                        {shorten_path(session.cwd)}
                      </span>
                      <%= if session.branch do %>
                        <span class="text-xs text-base-content/40">⎇ {session.branch}</span>
                      <% end %>
                    </.link>
                  </td>
                  <td class="align-middle text-right text-xs text-base-content/50 whitespace-nowrap">
                    <%= if session.event_count && session.event_count > 0 do %>
                      {format_number(session.event_count)}
                    <% end %>
                  </td>
                  <td class="align-middle text-right text-xs text-base-content/40 whitespace-nowrap">
                    {format_date(session.stopped_at || session.started_at)}
                  </td>
                  <td class="align-middle">
                    <%= unless session.starred do %>
                      <%= if @confirm_delete_id == session.id do %>
                        <div class="flex items-center gap-1">
                          <span class="text-xs text-error">Delete?</span>
                          <button
                            phx-click="delete_session"
                            phx-value-id={session.id}
                            class="btn btn-xs btn-error"
                          >
                            Yes
                          </button>
                          <button
                            phx-click="cancel_delete"
                            class="btn btn-xs btn-ghost"
                          >
                            No
                          </button>
                        </div>
                      <% else %>
                        <button
                          phx-click="confirm_delete"
                          phx-value-id={session.id}
                          class="btn btn-xs btn-error btn-outline opacity-0 group-hover:opacity-100 transition-opacity"
                        >
                          Delete
                        </button>
                      <% end %>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
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

    <%!-- Permissions Modal --%>
    <%= if @permissions_modal do %>
      <div
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm"
        id="permissions-modal"
        phx-window-keydown="close_permissions_modal"
        phx-key="Escape"
      >
        <div class="bg-base-100 rounded-2xl shadow-2xl border border-base-300 w-full max-w-lg mx-4 overflow-hidden">
          <%!-- Header --%>
          <div class="flex items-center justify-between px-6 pt-5 pb-3">
            <div class="flex items-center gap-2">
              <span class="text-xl">{agent_icon(@permissions_modal.agent)}</span>
              <h3 class="text-lg font-semibold text-base-content">
                New {agent_label(@permissions_modal.agent)} Session
              </h3>
            </div>
            <button
              phx-click="close_permissions_modal"
              class="btn btn-ghost btn-sm btn-circle text-base-content/50 hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>

          <%!-- Session info --%>
          <div class="px-6 pb-2 text-xs text-base-content/50 space-y-0.5">
            <div class="flex items-center gap-2">
              <span class="font-mono">{shorten_path(@permissions_modal.cwd)}</span>
            </div>
            <div>
              Model:
              <span class="badge badge-ghost badge-xs">{@permissions_modal.model || "auto"}</span>
            </div>
          </div>

          <%!-- Divider --%>
          <div class="px-6">
            <div class="border-t border-base-300 my-2"></div>
            <div class="text-xs font-semibold text-base-content/40 uppercase tracking-wider mb-3">
              Permissions
            </div>
          </div>

          <%!-- Permission options --%>
          <div class="px-6 pb-4 space-y-4 max-h-[50vh] overflow-y-auto">
            <%= for opt <- @permissions_modal.options do %>
              <%= if opt.type == :toggle do %>
                <div class="flex items-start gap-3">
                  <% checked = @permissions_modal.permissions[opt.key] in ["true", true] %>
                  <input
                    type="checkbox"
                    class="toggle toggle-sm toggle-primary mt-0.5"
                    checked={checked}
                    phx-click="toggle_permission"
                    phx-value-key={opt.key}
                  />
                  <div class="flex-1 min-w-0">
                    <div class="text-sm font-medium">{opt.label}</div>
                    <div class="text-xs text-base-content/50">{opt.description}</div>
                  </div>
                </div>
              <% else %>
                <div>
                  <label class="text-sm font-medium">{opt.label}</label>
                  <div class="text-xs text-base-content/50 mb-1">{opt.description}</div>
                  <form phx-change="update_permission">
                    <input type="hidden" name="key" value={opt.key} />
                    <select
                      class="select select-bordered select-sm w-full"
                      name="value"
                    >
                      <%= for {label, value} <- opt.choices do %>
                        <option
                          value={value}
                          selected={@permissions_modal.permissions[opt.key] == value}
                        >
                          {label}
                        </option>
                      <% end %>
                    </select>
                  </form>
                </div>
              <% end %>
            <% end %>

            <%= if @permissions_modal.options == [] do %>
              <div class="text-sm text-base-content/50 italic py-2">
                No configurable permissions for this agent.
              </div>
            <% end %>
          </div>

          <%!-- Footer --%>
          <div class="flex items-center justify-end gap-2 px-6 py-4 bg-base-200/50 border-t border-base-300">
            <button phx-click="close_permissions_modal" class="btn btn-ghost btn-sm">Cancel</button>
            <button phx-click="confirm_create_session" class="btn btn-primary btn-sm gap-1">
              <span>{agent_icon(@permissions_modal.agent)}</span> Start Session
            </button>
          </div>
        </div>
      </div>
    <% end %>
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

  defp format_number(nil), do: ""
  defp format_number(0), do: ""
  defp format_number(n) when is_integer(n), do: Integer.to_string(n)

  defp format_date(nil), do: ""

  defp format_date(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
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
