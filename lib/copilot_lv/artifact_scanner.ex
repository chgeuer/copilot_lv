defmodule CopilotLv.ArtifactScanner do
  @moduledoc """
  Discovers significant text artifacts produced by coding-agent sessions.

  Scanning is restricted to known session-owned directories, rejects generated
  dependency/build trees, skips binary content, and stores bounded previews for
  oversized text files.
  """

  @max_content_bytes 2 * 1024 * 1024
  @preview_bytes 128 * 1024

  @extensions MapSet.new(~w(.md .txt .adoc .rst .yaml .yml .toml .diff .patch .csv))
  @excluded_segments MapSet.new(~w(
                         .git .hg .svn .venv venv node_modules vendor deps _build
                         build dist target site-packages __pycache__ cache caches
                         rewind-snapshots rewind-file-snapshots
                       ))

  @mime_types %{
    ".md" => "text/markdown",
    ".txt" => "text/plain",
    ".adoc" => "text/asciidoc",
    ".rst" => "text/x-rst",
    ".yaml" => "application/yaml",
    ".yml" => "application/yaml",
    ".toml" => "application/toml",
    ".diff" => "text/x-diff",
    ".patch" => "text/x-diff",
    ".csv" => "text/csv"
  }

  @type report :: %{artifacts: [map()], excluded: %{optional(atom()) => non_neg_integer()}}

  @doc "Scans the significant sidecar locations belonging to one session."
  @spec scan_session(atom(), String.t(), String.t()) :: report()
  def scan_session(:copilot, _session_id, session_dir) do
    specs =
      top_level_documents(session_dir) ++
        directory_specs(session_dir, ["files", "research", "tool-results"])

    scan_specs(session_dir, specs, :copilot)
  end

  def scan_session(:claude, session_id, jsonl_path) do
    session_dir = Path.join(Path.dirname(jsonl_path), session_id)
    specs = directory_specs(session_dir, ["tool-results"])
    scan_specs(session_dir, specs, :claude)
  end

  def scan_session(:gemini, session_id, chat_path) do
    project_dir = chat_path |> Path.dirname() |> Path.dirname()
    short_id = gemini_short_id(chat_path)

    specs =
      project_dir
      |> Path.join("tool-outputs/session-*")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        basename = Path.basename(path)
        String.contains?(basename, session_id) or String.contains?(basename, short_id)
      end)
      |> Enum.map(&{:directory, &1, "tool-outputs/#{Path.basename(&1)}", :tool_output})

    scan_specs(project_dir, specs, :gemini)
  end

  def scan_session(_agent, _session_id, _source_path), do: empty_report()

  @doc "Scans project-level memory documents associated with a session source."
  @spec scan_project_documents(atom(), String.t(), String.t()) :: report()
  def scan_project_documents(:claude, project_key, jsonl_path) do
    project_dir = Path.dirname(jsonl_path)
    memory_dir = Path.join(project_dir, "memory")

    scan_specs(
      project_dir,
      [{:directory, memory_dir, "memory", :project_memory}],
      :claude,
      project_key
    )
  end

  def scan_project_documents(_agent, _project_key, _source_path), do: empty_report()

  @doc "Maximum number of source bytes stored without truncation."
  def max_content_bytes, do: @max_content_bytes

  defp top_level_documents(session_dir) do
    session_dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&(File.regular?(&1) and allowed_extension?(&1)))
    |> Enum.map(fn path ->
      category =
        if String.downcase(Path.extname(path)) in [".md", ".adoc", ".rst"],
          do: :authored_document,
          else: :metadata

      {:file, path, Path.basename(path), category}
    end)
  end

  defp directory_specs(root, names) do
    Enum.map(names, fn name ->
      category = if name == "tool-results", do: :tool_output, else: :authored_document
      {:directory, Path.join(root, name), name, category}
    end)
  end

  defp scan_specs(base_dir, specs, agent, project_key \\ nil) do
    paths =
      specs
      |> Enum.flat_map(&expand_spec/1)
      |> Enum.uniq_by(fn {_path, relative_path, _category} -> relative_path end)

    {artifacts, excluded} =
      Enum.reduce(paths, {[], %{}}, fn {path, relative_path, category}, {artifacts, excluded} ->
        case read_artifact(path, relative_path, category, agent, base_dir, project_key) do
          {:ok, artifact} -> {[artifact | artifacts], excluded}
          {:excluded, reason} -> {artifacts, Map.update(excluded, reason, 1, &(&1 + 1))}
        end
      end)

    %{artifacts: Enum.sort_by(artifacts, & &1.path), excluded: excluded}
  end

  defp expand_spec({:file, path, relative_path, category}) do
    [{path, relative_path, category}]
  end

  defp expand_spec({:directory, dir, prefix, category}) do
    if File.dir?(dir) do
      walk_directory(dir, prefix, category)
    else
      []
    end
  end

  defp walk_directory(dir, prefix, category) do
    dir
    |> File.ls()
    |> case do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)
          relative_path = Path.join(prefix, entry)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} ->
              if excluded_path?(relative_path) do
                []
              else
                walk_directory(path, relative_path, category)
              end

            {:ok, %File.Stat{type: :regular}} ->
              [{path, relative_path, category}]

            _ ->
              []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp read_artifact(path, relative_path, category, agent, base_dir, project_key) do
    cond do
      excluded_path?(relative_path) ->
        {:excluded, :excluded_path}

      not allowed_extension?(path) ->
        {:excluded, :unsupported_extension}

      true ->
        with {:ok, stat} <- File.stat(path, time: :posix),
             {:ok, sample} <- read_sample(path),
             true <- text_content?(sample) do
          {content, truncated?} = read_content(path, stat.size)

          if text_content?(content) do
            hash = hash_file(path)

            {:ok,
             %{
               path: relative_path,
               source_path: Path.relative_to(path, base_dir),
               content: content,
               content_hash: hash,
               artifact_type: artifact_type(relative_path),
               category: category,
               source_agent: agent,
               mime_type: Map.fetch!(@mime_types, String.downcase(Path.extname(path))),
               modified_at: DateTime.from_unix!(stat.mtime),
               size: stat.size,
               original_size: stat.size,
               stored_size: byte_size(content),
               truncated: truncated?,
               managed: is_nil(project_key),
               project_key: project_key
             }}
          else
            {:excluded, :binary}
          end
        else
          false -> {:excluded, :binary}
          {:error, _reason} -> {:excluded, :unreadable}
        end
    end
  end

  defp read_sample(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        result = :file.read(file, 8 * 1024)
        File.close(file)

        case result do
          {:ok, sample} -> {:ok, sample}
          :eof -> {:ok, ""}
          error -> error
        end

      error ->
        error
    end
  end

  defp read_content(path, size) when size <= @max_content_bytes do
    {File.read!(path), false}
  end

  defp read_content(path, size) do
    {:ok, file} = File.open(path, [:read, :binary])
    {:ok, head} = :file.pread(file, 0, @preview_bytes)
    {:ok, tail} = :file.pread(file, max(size - @preview_bytes, 0), @preview_bytes)
    File.close(file)

    marker =
      "\n\n--- content truncated; #{size - byte_size(head) - byte_size(tail)} bytes omitted ---\n\n"

    {head <> marker <> tail, true}
  end

  defp hash_file(path) do
    context =
      path
      |> File.stream!(64 * 1024, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))

    context
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp text_content?(sample) do
    if String.contains?(sample, <<0>>) or not String.valid?(sample) do
      false
    else
      invalid_controls =
        sample
        |> :binary.bin_to_list()
        |> Enum.count(&(&1 < 32 and &1 not in [9, 10, 13]))

      invalid_controls <= max(div(byte_size(sample), 100), 1)
    end
  end

  defp excluded_path?(relative_path) do
    relative_path
    |> Path.split()
    |> Enum.any?(fn segment -> MapSet.member?(@excluded_segments, String.downcase(segment)) end)
  end

  defp allowed_extension?(path) do
    MapSet.member?(@extensions, String.downcase(Path.extname(path)))
  end

  defp artifact_type(path) do
    case Path.basename(path) do
      "plan.md" -> :plan
      "workspace.yaml" -> :workspace
      _ -> :file
    end
  end

  defp gemini_short_id(chat_path) do
    case Regex.run(~r/-([0-9a-f]+)\.json$/, Path.basename(chat_path)) do
      [_, id] -> id
      _ -> ""
    end
  end

  defp empty_report, do: %{artifacts: [], excluded: %{}}
end
