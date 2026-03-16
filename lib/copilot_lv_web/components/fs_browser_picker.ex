defmodule CopilotLvWeb.FsBrowserPicker do
  use Phoenix.Component
  import CopilotLvWeb.CoreComponents, only: [icon: 1]

  @indent 20
  @rail_offset 14

  attr :id, :string, default: "fs-browser-picker"
  attr :current_path, :string, required: true
  attr :open, :boolean, default: false
  attr :expanded_dirs, :map, default: %{}
  attr :name, :string, default: "session[cwd]"

  def fs_browser_picker(assigns) do
    tree = build_visible_tree(assigns.current_path, assigns.expanded_dirs)
    flat = flatten_tree(tree, 0, [])

    assigns =
      assign(assigns,
        flat_entries: flat,
        indent: @indent,
        short_path: shorten_path(assigns.current_path)
      )

    ~H"""
    <div class="form-control flex-1" id={@id}>
      <label class="label py-1">
        <span class="label-text text-xs">Working Directory</span>
      </label>
      <div class="relative" phx-click-away="fs_picker_close">
        <button
          type="button"
          phx-click="fs_picker_toggle"
          class={[
            "flex items-center gap-2 w-full h-8 px-3 rounded-lg border text-left text-sm transition-colors",
            "border-base-300 bg-base-100 hover:border-primary/40"
          ]}
        >
          <.icon name="hero-folder" class="w-4 h-4 text-warning shrink-0" />
          <span class="font-mono text-xs truncate flex-1">{@short_path}</span>
          <.icon
            name="hero-chevron-down"
            class={[
              "w-3.5 h-3.5 shrink-0 text-base-content/40 transition-transform",
              @open && "rotate-180"
            ]}
          />
        </button>
        <input type="hidden" name={@name} value={@current_path} />

        <div
          :if={@open}
          class="absolute top-full left-0 right-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-xl max-h-80 overflow-y-auto z-50 min-w-[320px]"
        >
          <div class="py-1.5 px-1">
            <div class="flex items-center gap-1 px-2 py-1 text-xs text-base-content/50 font-semibold">
              <.icon name="hero-folder-open" class="w-3.5 h-3.5" /> Browse filesystem
            </div>
            <div class="border-t border-base-200 my-1"></div>
            <%= for entry <- @flat_entries do %>
              <.fs_tree_row
                entry={entry}
                current_path={@current_path}
                expanded_dirs={@expanded_dirs}
                indent={@indent}
              />
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp fs_tree_row(assigns) do
    is_selected = assigns.entry.full_path == assigns.current_path
    is_expanded = Map.has_key?(assigns.expanded_dirs, assigns.entry.full_path)
    assigns = assign(assigns, is_selected: is_selected, is_expanded: is_expanded)

    ~H"""
    <div class="flex items-center group">
      <button
        type="button"
        phx-click="fs_picker_toggle_dir"
        phx-value-path={@entry.full_path}
        class={[
          "flex items-center flex-1 w-full h-7 rounded text-sm transition-colors text-left relative",
          if(@is_selected,
            do: "bg-primary/20 text-primary font-medium",
            else: "hover:bg-primary/10"
          )
        ]}
        style={"padding-left: #{@entry.depth * @indent + 8}px; padding-right: 8px;"}
      >
        <.tree_lines
          rails={@entry.rails}
          depth={@entry.depth}
          is_last={@entry.is_last}
          indent={@indent}
        />
        <.icon
          name={if(@is_expanded, do: "hero-chevron-down", else: "hero-chevron-right")}
          class="w-3 h-3 shrink-0 mr-0.5 text-base-content/40"
        />
        <.icon
          name={if(@is_expanded, do: "hero-folder-open", else: "hero-folder")}
          class="w-4 h-4 text-warning shrink-0 mr-1.5"
        />
        <span class="font-mono text-xs truncate">{@entry.name}</span>
      </button>
      <button
        type="button"
        phx-click="fs_picker_select"
        phx-value-path={@entry.full_path}
        class={[
          "shrink-0 px-1.5 py-0.5 rounded text-xs transition-all mr-1",
          if(@is_selected,
            do: "bg-primary text-primary-content",
            else: "opacity-0 group-hover:opacity-100 bg-primary/10 text-primary hover:bg-primary/20"
          )
        ]}
      >
        <%= if @is_selected do %>
          ✓
        <% else %>
          Select
        <% end %>
      </button>
    </div>
    """
  end

  defp tree_lines(%{depth: 0} = assigns), do: ~H""

  defp tree_lines(assigns) do
    assigns = assign(assigns, :rail_offset, @rail_offset)

    ~H"""
    <%= for {active, level} <- Enum.with_index(@rails) do %>
      <span
        :if={active && level < @depth - 1}
        class="absolute top-0 bottom-0 border-l border-base-content/15"
        style={"left: #{level * @indent + @rail_offset}px;"}
      >
      </span>
    <% end %>
    <span
      class="absolute border-l border-b border-base-content/15 rounded-bl-sm"
      style={"left: #{(@depth - 1) * @indent + @rail_offset}px; width: #{@indent - @rail_offset + 6}px; bottom: 50%; height: 50%;"}
    >
    </span>
    <span
      :if={!@is_last}
      class="absolute border-l border-base-content/15"
      style={"left: #{(@depth - 1) * @indent + @rail_offset}px; top: 50%; bottom: 0;"}
    >
    </span>
    """
  end

  defp build_visible_tree(current_path, expanded_dirs) do
    root_entries = list_dirs("/")

    root_node = %{
      name: "/",
      full_path: "/",
      children: build_children("/", root_entries, current_path, expanded_dirs)
    }

    %{"/" => root_node}
  end

  defp build_children(parent_path, child_names, current_path, expanded_dirs) do
    path_segments = path_segments(current_path)

    child_names
    |> Enum.map(fn name ->
      full_path = Path.join(parent_path, name)
      is_on_active_path = full_path in path_segments
      is_expanded = Map.has_key?(expanded_dirs, full_path) || is_on_active_path

      children =
        if is_expanded do
          case list_dirs(full_path) do
            entries when entries != [] ->
              build_children(full_path, entries, current_path, expanded_dirs)

            _ ->
              %{}
          end
        else
          %{}
        end

      {name, %{name: name, full_path: full_path, children: children}}
    end)
    |> Map.new()
  end

  defp flatten_tree(tree, depth, ancestor_rails) do
    sorted_keys = Enum.sort(Map.keys(tree))
    total = length(sorted_keys)

    sorted_keys
    |> Enum.with_index()
    |> Enum.flat_map(fn {key, idx} ->
      node = Map.get(tree, key)
      is_last = idx == total - 1
      has_children = map_size(node.children) > 0
      rails_for_children = ancestor_rails ++ [!is_last]

      self_entry = %{
        name: node.name,
        full_path: node.full_path,
        depth: depth,
        is_last: is_last,
        rails: ancestor_rails
      }

      child_entries =
        if has_children do
          flatten_tree(node.children, depth + 1, rails_for_children)
        else
          []
        end

      [self_entry | child_entries]
    end)
  end

  defp list_dirs(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          full = Path.join(path, entry)
          not String.starts_with?(entry, ".") and File.dir?(full)
        end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp path_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce(["/"], fn segment, acc ->
      parent = hd(acc)
      [Path.join(parent, segment) | acc]
    end)
    |> Enum.reverse()
  end

  defp shorten_path(path) do
    home = System.user_home!()

    if String.starts_with?(path, home) do
      "~" <> String.trim_leading(path, home)
    else
      path
    end
  end
end
