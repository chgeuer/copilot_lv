defmodule CopilotLvWeb.DirTreePicker do
  @moduledoc """
  A tree-view directory picker dropdown for filtering sessions by directory.

  Renders a flat list of directories as an indented directory tree with
  CSS-drawn connector lines. Supports collapsible nodes and text filtering.
  """
  use Phoenix.Component
  import CopilotLvWeb.CoreComponents, only: [icon: 1]

  @indent 20
  @rail_offset 14

  attr :dirs, :list, required: true, doc: "List of {label, full_path} tuples"
  attr :selected, :string, default: "", doc: "Currently selected full path"
  attr :open, :boolean, default: false, doc: "Whether the dropdown is open"
  attr :collapsed, :any, default: nil, doc: "MapSet of collapsed node paths"
  attr :filter, :string, default: "", doc: "Text filter for tree entries"

  def dir_tree_picker(assigns) do
    collapsed = assigns.collapsed || MapSet.new()
    filter = String.trim(assigns.filter || "")

    tree = build_tree(assigns.dirs)

    tree =
      if filter != "" do
        filter_tree(tree, String.downcase(filter))
      else
        tree
      end

    flat = flatten_tree(tree, 0, [], collapsed, [])
    assigns = assign(assigns, flat_entries: flat, indent: @indent)

    selected_label =
      case Enum.find(assigns.dirs, fn {_label, val} -> val == assigns.selected end) do
        {label, _} -> label
        nil -> "All directories"
      end

    assigns = assign(assigns, :selected_label, selected_label)

    ~H"""
    <div class="relative" id="dir-tree-picker" phx-click-away="close_dir_picker">
      <button
        type="button"
        phx-click="toggle_dir_picker"
        class={[
          "select select-bordered select-sm flex items-center gap-1 min-w-[180px] max-w-[280px] text-left",
          @selected != "" && "text-primary font-medium"
        ]}
      >
        <.icon name="hero-folder" class="w-3.5 h-3.5 shrink-0 opacity-60" />
        <span class="truncate text-xs">{@selected_label}</span>
      </button>

      <div
        :if={@open}
        class="absolute top-full left-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-xl max-h-96 overflow-y-auto z-50 min-w-[320px] max-w-[480px]"
      >
        <div class="sticky top-0 bg-base-100 px-2 pt-2 pb-1 z-10">
          <input
            type="text"
            placeholder="Filter directories…"
            value={@filter}
            phx-keyup="dir_picker_filter"
            phx-key=""
            class="input input-bordered input-xs w-full font-mono"
            autocomplete="off"
            phx-debounce="150"
          />
        </div>
        <div class="py-1.5 px-1">
          <button
            type="button"
            phx-click="select_dir"
            phx-value-dir=""
            class={[
              "flex items-center w-full h-7 rounded text-sm transition-colors text-left px-2",
              if(@selected == "",
                do: "bg-primary/20 text-primary font-medium",
                else: "hover:bg-primary/10"
              )
            ]}
          >
            <.icon name="hero-folder" class="w-4 h-4 text-warning shrink-0 mr-1.5" />
            <span class="text-xs">All directories</span>
          </button>
          <div class="border-t border-base-200 my-1"></div>
          <%= for entry <- @flat_entries do %>
            <.tree_row entry={entry} selected={@selected} indent={@indent} />
          <% end %>
          <%= if @flat_entries == [] and @filter != "" do %>
            <div class="text-xs text-base-content/40 text-center py-3">No matching directories</div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp tree_row(%{entry: %{selectable: true}} = assigns) do
    ~H"""
    <div class="flex items-center relative" style={"padding-left: #{@entry.depth * @indent + 8}px;"}>
      <.tree_lines
        rails={@entry.rails}
        depth={@entry.depth}
        is_last={@entry.is_last}
        indent={@indent}
      />
      <button
        :if={@entry.has_children}
        type="button"
        phx-click="dir_picker_toggle_node"
        phx-value-path={@entry.node_path}
        class="w-4 h-4 flex items-center justify-center shrink-0 text-base-content/40 hover:text-base-content/70 transition-colors"
      >
        <.icon
          name={if(@entry.collapsed, do: "hero-chevron-right-mini", else: "hero-chevron-down-mini")}
          class="w-3 h-3"
        />
      </button>
      <span :if={!@entry.has_children} class="w-4 shrink-0"></span>
      <button
        type="button"
        phx-click="select_dir"
        phx-value-dir={@entry.full_path}
        class={[
          "flex items-center flex-1 h-7 rounded text-sm transition-colors text-left pr-2",
          if(@entry.full_path == @selected,
            do: "bg-primary/20 text-primary font-medium",
            else: "hover:bg-primary/10"
          )
        ]}
      >
        <.icon name="hero-folder" class="w-4 h-4 text-warning shrink-0 mr-1.5" />
        <span class="font-mono text-xs truncate">{@entry.name}</span>
        <span class="ml-auto text-xs text-base-content/40 tabular-nums pl-2">{@entry.count}</span>
      </button>
    </div>
    """
  end

  defp tree_row(%{entry: %{selectable: false}} = assigns) do
    ~H"""
    <div
      class="flex items-center w-full h-7 text-sm text-base-content/50 relative"
      style={"padding-left: #{@entry.depth * @indent + 8}px; padding-right: 8px;"}
    >
      <.tree_lines
        rails={@entry.rails}
        depth={@entry.depth}
        is_last={@entry.is_last}
        indent={@indent}
      />
      <button
        :if={@entry.has_children}
        type="button"
        phx-click="dir_picker_toggle_node"
        phx-value-path={@entry.node_path}
        class="w-4 h-4 flex items-center justify-center shrink-0 text-base-content/40 hover:text-base-content/70 transition-colors"
      >
        <.icon
          name={if(@entry.collapsed, do: "hero-chevron-right-mini", else: "hero-chevron-down-mini")}
          class="w-3 h-3"
        />
      </button>
      <span :if={!@entry.has_children} class="w-4 shrink-0"></span>
      <.icon name="hero-folder-open" class="w-4 h-4 text-warning/60 shrink-0 mr-1.5" />
      <span class="font-mono text-xs truncate">{@entry.name}</span>
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

  # ── Tree Building ──

  defp build_tree(dirs) do
    Enum.reduce(dirs, %{}, fn {label, full_path}, acc ->
      {short, count} = parse_label(label)
      segments = split_path(short)
      insert_into_tree(acc, segments, count, full_path)
    end)
  end

  defp parse_label(label) do
    case Regex.run(~r/^(.+?)\s+\((\d+)\)$/, label) do
      [_, path, count] -> {path, String.to_integer(count)}
      _ -> {label, 0}
    end
  end

  defp split_path("~"), do: ["~"]
  defp split_path("~/" <> rest), do: ["~" | String.split(rest, "/", trim: true)]

  defp split_path("/" <> _ = path),
    do: ["/" | String.split(path, "/", trim: true)]

  defp split_path(other), do: [other]

  defp insert_into_tree(tree, [single], count, full_path) do
    node = Map.get(tree, single, %{children: %{}, count: nil, full_path: nil})
    Map.put(tree, single, %{node | count: count, full_path: full_path})
  end

  defp insert_into_tree(tree, [head | rest], count, full_path) do
    node = Map.get(tree, head, %{children: %{}, count: nil, full_path: nil})
    updated_children = insert_into_tree(node.children, rest, count, full_path)
    Map.put(tree, head, %{node | children: updated_children})
  end

  # ── Filtering ──

  defp filter_tree(tree, query) do
    tree
    |> Enum.flat_map(fn {key, node} ->
      name_matches = String.contains?(String.downcase(key), query)
      self_matches = name_matches && node.count != nil

      path_matches =
        node.full_path != nil && String.contains?(String.downcase(node.full_path), query)

      filtered_children = filter_tree(node.children, query)

      if self_matches || path_matches || filtered_children != [] do
        [{key, %{node | children: Map.new(filtered_children)}}]
      else
        []
      end
    end)
  end

  # ── Flattening with Collapse Support ──

  defp flatten_tree(tree, depth, ancestor_rails, collapsed, parent_path_parts) do
    sorted_keys = Enum.sort(Map.keys(tree))
    total = length(sorted_keys)

    sorted_keys
    |> Enum.with_index()
    |> Enum.flat_map(fn {key, idx} ->
      node = Map.get(tree, key)
      is_last = idx == total - 1
      has_children = map_size(node.children) > 0
      rails_for_children = ancestor_rails ++ [!is_last]
      node_path = Enum.join(parent_path_parts ++ [key], "/")
      is_collapsed = MapSet.member?(collapsed, node_path)

      self_entry =
        if node.count do
          [
            %{
              name: key,
              depth: depth,
              is_last: is_last,
              rails: ancestor_rails,
              selectable: true,
              count: node.count,
              full_path: node.full_path,
              has_children: has_children,
              collapsed: is_collapsed,
              node_path: node_path
            }
          ]
        else
          [
            %{
              name: key,
              depth: depth,
              is_last: is_last && !has_children,
              rails: ancestor_rails,
              selectable: false,
              count: nil,
              full_path: nil,
              has_children: has_children,
              collapsed: is_collapsed,
              node_path: node_path
            }
          ]
        end

      child_entries =
        if has_children && !is_collapsed do
          flatten_tree(
            node.children,
            depth + 1,
            rails_for_children,
            collapsed,
            parent_path_parts ++ [key]
          )
        else
          []
        end

      self_entry ++ child_entries
    end)
  end
end
