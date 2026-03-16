defmodule CopilotLvWeb.FileTreePicker do
  @moduledoc """
  A live tree-view file picker component with CSS-drawn connector lines.

  Renders a flat list of file suggestions as an indented directory tree
  with proper visual connector lines (vertical rails + horizontal branches).
  Typing a file name filters the tree in real time, keeping ancestor
  directories visible so the user always sees structure.

  ## Usage

      <.file_tree_picker
        suggestions={@file_suggestions}
        query={@file_query}
        picker_index={@file_picker_index}
      />

  Each entry in `suggestions` must be a map with:
    * `:path` – absolute path
    * `:type` – `"file"` or `"directory"`
    * `:display_name` – relative path (directories end with `/`)
  """
  use Phoenix.Component
  import CopilotLvWeb.CoreComponents, only: [icon: 1]

  # Pixels per indent level
  @indent 20
  # X offset for guide rails within each indent column
  @rail_offset 14

  attr :suggestions, :list, required: true, doc: "List of file/dir maps"
  attr :query, :string, default: ""
  attr :picker_index, :integer, default: -1

  def file_tree_picker(assigns) do
    tree = build_tree(assigns.suggestions)
    flat = flatten_tree(tree, 0, [])
    assigns = assign(assigns, flat_entries: flat, indent: @indent)

    ~H"""
    <div
      id="file-tree-picker"
      class="absolute bottom-full left-0 right-0 mb-1 bg-base-100 border border-base-300 rounded-lg shadow-xl max-h-72 overflow-y-auto z-50"
    >
      <div class="py-1.5 px-1">
        <div class="text-xs text-base-content/50 px-2 py-1 font-semibold">
          <%= if @query == "" do %>
            Files in project
          <% else %>
            Files matching "{@query}"
          <% end %>
        </div>
        <%= for entry <- @flat_entries do %>
          <.tree_row entry={entry} picker_index={@picker_index} indent={@indent} />
        <% end %>
      </div>
    </div>
    """
  end

  # ── Row Components ──

  defp tree_row(%{entry: %{selectable: true}} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_file"
      phx-value-path={@entry.file.path}
      phx-value-type={@entry.file.type}
      phx-value-name={@entry.file.display_name}
      data-picker-index={@entry.flat_index}
      class={[
        "file-tree-row group flex items-center w-full h-7 rounded text-sm transition-colors text-left relative",
        if(@entry.flat_index == @picker_index,
          do: "bg-primary/20 text-primary-content",
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
      <%= if @entry.file.type == "directory" do %>
        <.icon name="hero-folder" class="w-4 h-4 text-warning shrink-0 mr-1.5" />
      <% else %>
        <.icon name="hero-document" class="w-4 h-4 text-info shrink-0 mr-1.5" />
      <% end %>
      <span class="font-mono text-xs truncate">{@entry.name}</span>
    </button>
    """
  end

  defp tree_row(%{entry: %{selectable: false}} = assigns) do
    ~H"""
    <div
      class="file-tree-row flex items-center w-full h-7 text-sm text-base-content/50 relative"
      style={"padding-left: #{@entry.depth * @indent + 8}px; padding-right: 8px;"}
    >
      <.tree_lines
        rails={@entry.rails}
        depth={@entry.depth}
        is_last={@entry.is_last}
        indent={@indent}
      />
      <.icon name="hero-folder" class="w-4 h-4 text-warning/60 shrink-0 mr-1.5" />
      <span class="font-mono text-xs truncate">{@entry.name}</span>
    </div>
    """
  end

  # ── Tree Lines ──

  # Renders all visual lines for a tree row:
  # 1. Vertical "rails" for ancestor levels that still have siblings below
  # 2. The L-shaped connector from this item's parent rail to the item
  defp tree_lines(%{depth: 0} = assigns), do: ~H""

  defp tree_lines(assigns) do
    rail_offset = @rail_offset
    assigns = assign(assigns, :rail_offset, rail_offset)

    ~H"""
    <%!-- Vertical rails for ancestors that have more siblings.
         Skip the last rail (depth-1) since the connector handles that level. --%>
    <%= for {active, level} <- Enum.with_index(@rails) do %>
      <span
        :if={active && level < @depth - 1}
        class="absolute top-0 bottom-0 border-l border-base-content/15"
        style={"left: #{level * @indent + @rail_offset}px;"}
      >
      </span>
    <% end %>

    <%!-- L-shaped connector: vertical half + horizontal branch to this item --%>
    <span
      class="absolute border-l border-b border-base-content/15 rounded-bl-sm"
      style={"left: #{(@depth - 1) * @indent + @rail_offset}px; width: #{@indent - @rail_offset + 6}px; bottom: 50%; height: 50%;"}
    >
    </span>

    <%!-- Vertical continuation below the connector (only if not last sibling) --%>
    <span
      :if={!@is_last}
      class="absolute border-l border-base-content/15"
      style={"left: #{(@depth - 1) * @indent + @rail_offset}px; top: 50%; bottom: 0;"}
    >
    </span>
    """
  end

  # ── Tree Building ──

  defp build_tree(suggestions) do
    Enum.reduce(suggestions, %{}, fn file, acc ->
      parts = split_path(file.display_name)
      insert_into_tree(acc, parts, file)
    end)
  end

  defp split_path(display_name) do
    display_name
    |> String.trim_trailing("/")
    |> String.split("/")
  end

  defp insert_into_tree(tree, [single], file) do
    node = Map.get(tree, single, %{__files__: [], __children__: %{}})
    node = %{node | __files__: node.__files__ ++ [file]}
    Map.put(tree, single, node)
  end

  defp insert_into_tree(tree, [head | rest], file) do
    node = Map.get(tree, head, %{__files__: [], __children__: %{}})
    updated_children = insert_into_tree(node.__children__, rest, file)
    node = %{node | __children__: updated_children}
    Map.put(tree, head, node)
  end

  # ── Tree Flattening ──

  # `ancestor_rails` is a list of booleans for each ancestor depth, indicating
  # whether a vertical rail should be drawn at that depth level.
  #
  # `ancestor_rails[i]` = true means: "the ancestor at depth i is NOT the last
  # sibling at its level, so a vertical line connects it to its next sibling
  # and must pass through all descendant rows."
  defp flatten_tree(tree, depth, ancestor_rails) do
    sorted_keys = Enum.sort(Map.keys(tree))
    total = length(sorted_keys)

    {entries, _} =
      sorted_keys
      |> Enum.with_index()
      |> Enum.reduce({[], 0}, fn {key, idx}, {acc, flat_idx} ->
        node = Map.get(tree, key)
        is_last = idx == total - 1
        has_children = map_size(node.__children__) > 0
        files = node.__files__

        # Rails passed to this node's CHILDREN:
        # - All ancestor rails (inherited from above)
        # - Plus: whether THIS node (the child's parent) is NOT the last sibling.
        #   If it's not last, a vertical rail at this depth continues through
        #   all the children's rows, connecting this node to its next sibling.
        rails_for_children = ancestor_rails ++ [!is_last]

        case files do
          [file] when not has_children ->
            entry = %{
              name: key <> if(file.type == "directory", do: "/", else: ""),
              depth: depth,
              is_last: is_last,
              rails: ancestor_rails,
              file: file,
              selectable: true,
              flat_index: flat_idx
            }

            {acc ++ [entry], flat_idx + 1}

          _ ->
            dir_file = Enum.find(files, fn f -> f.type == "directory" end)

            if dir_file do
              dir_entry = %{
                name: key <> "/",
                depth: depth,
                is_last: is_last,
                rails: ancestor_rails,
                file: dir_file,
                selectable: true,
                flat_index: flat_idx
              }

              child_entries = flatten_tree(node.__children__, depth + 1, rails_for_children)
              {reindexed_children, next_idx} = reindex(child_entries, flat_idx + 1)
              {acc ++ [dir_entry] ++ reindexed_children, next_idx}
            else
              dir_entry = %{
                name: key <> "/",
                depth: depth,
                is_last: is_last,
                rails: ancestor_rails,
                file: nil,
                selectable: false,
                flat_index: nil
              }

              child_entries = flatten_tree(node.__children__, depth + 1, rails_for_children)
              {reindexed_children, next_idx} = reindex(child_entries, flat_idx)
              {acc ++ [dir_entry] ++ reindexed_children, next_idx}
            end
        end
      end)

    entries
  end

  defp reindex(entries, start) do
    {reindexed, next} =
      Enum.reduce(entries, {[], start}, fn entry, {acc, idx} ->
        if entry.selectable do
          {acc ++ [%{entry | flat_index: idx}], idx + 1}
        else
          {acc ++ [entry], idx}
        end
      end)

    {reindexed, next}
  end
end
