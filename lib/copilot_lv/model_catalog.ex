defmodule CopilotLv.ModelCatalog do
  @moduledoc """
  Per-agent model catalog for the session model selectors.

  Combines a *curated* list of known/available models for each agent with the
  set of models that were *actually used* in the recorded session history
  (discovered from the database). This guarantees the selectors always offer
  both currently-available models and any model the user has used before — for
  example `claude-opus-4-8` ("Claude Opus 4.8") or `claude-fable-5`
  ("Claude Fable 5").

  Discovery is relatively expensive (a scan over the `events` table), so the
  result is cached in a `:persistent_term`. Session, event, and usage writes
  register newly observed models incrementally. Bulk database changes can
  invalidate the cache so the next selector read repopulates it.

  Claude per-turn models are *not* stored in `sessions.model` (which is `NULL`
  for most Claude sessions); they live inside the event payload JSON. The
  discovery query therefore unions `sessions.model` with the model extracted
  from the event payloads.
  """

  require Logger

  @used_models_key {__MODULE__, :used_models}
  @cache_lock {__MODULE__, :cache_lock}

  # Curated, currently-available models per agent as
  # `{display_name, cli_model_value, premium_multiplier}`. The `cli_model_value`
  # must be a value the agent's CLI accepts for `--model`. Aliases like
  # `"opus"`/`"sonnet"`/`"haiku"` resolve to the latest model of that tier;
  # specific historical versions are added automatically from session history.
  @claude [
    {"Claude Haiku (latest)", "haiku", 0.33},
    {"Claude Sonnet (latest)", "sonnet", 1},
    {"Claude Opus (latest)", "opus", 3}
  ]

  @codex [
    {"GPT-4.1", "gpt-4.1", 1},
    {"GPT-4.1 mini", "gpt-4.1-mini", 0.33},
    {"o3", "o3", 1},
    {"o4-mini", "o4-mini", 0.33}
  ]

  @gemini [
    {"Gemini 3 Pro (Preview)", "gemini-3-pro-preview", 1},
    {"Gemini 3 Flash (Preview)", "gemini-3-flash-preview", 0.33},
    {"Gemini 2.5 Pro", "gemini-2.5-pro", 1},
    {"Gemini 2.5 Flash", "gemini-2.5-flash", 0.25}
  ]

  @doc """
  Discovers the models used in session history and caches them per agent.

  Also feeds the discovered Copilot models into `Jido.GHCopilot.Models` so the
  Copilot catalog (`Jido.GHCopilot.Models.all/0`) stays in sync. Safe to call
  repeatedly; failures are logged and leave an empty cache.
  """
  @spec refresh() :: :ok
  def refresh do
    :global.trans(@cache_lock, fn ->
      used = discover_used_models()
      :persistent_term.put(@used_models_key, used)
      Jido.GHCopilot.Models.register_session_models(Map.get(used, "copilot", []))
    end)

    :ok
  rescue
    e ->
      Logger.warning("CopilotLv.ModelCatalog.refresh/0 failed: #{Exception.message(e)}")
      :persistent_term.put(@used_models_key, %{})
      :ok
  end

  @doc "Invalidates the cached model list so the next read reloads it from the database."
  @spec invalidate() :: :ok
  def invalidate do
    :global.trans(@cache_lock, fn -> :persistent_term.erase(@used_models_key) end)
    :ok
  end

  @doc "Adds a newly observed model to the cached catalog without rescanning history."
  @spec observe_model(atom() | String.t(), String.t() | nil) :: :ok
  def observe_model(_agent, model) when not is_binary(model) or model == "", do: :ok

  def observe_model(agent, model) when is_atom(agent),
    do: observe_model(Atom.to_string(agent), model)

  def observe_model(agent, model) when is_binary(agent) do
    :global.trans(@cache_lock, fn ->
      case :persistent_term.get(@used_models_key, :not_loaded) do
        :not_loaded ->
          :ok

        used ->
          updated = Map.update(used, agent, [model], &Enum.uniq([model | &1]))
          :persistent_term.put(@used_models_key, updated)

          if agent == "copilot" do
            Jido.GHCopilot.Models.register_session_models(Map.fetch!(updated, agent))
          end
      end
    end)

    :ok
  end

  @doc "Adds model ids found in persisted event payloads to the cached catalog."
  @spec observe_event_models(atom() | String.t(), [map()]) :: :ok
  def observe_event_models(agent, events) do
    events
    |> Enum.map(&Map.get(&1, :data, Map.get(&1, "data", %{})))
    |> Enum.map(&event_model/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&observe_model(agent, &1))

    :ok
  end

  @doc "Returns model ids used by `agent`, lazily refreshing an invalidated cache."
  @spec used_models(atom() | String.t()) :: [String.t()]
  def used_models(agent) when is_atom(agent), do: used_models(Atom.to_string(agent))

  def used_models(agent) when is_binary(agent) do
    used =
      case :persistent_term.get(@used_models_key, :not_loaded) do
        :not_loaded ->
          refresh()
          :persistent_term.get(@used_models_key, %{})

        cached ->
          cached
      end

    Map.get(used, agent, [])
  end

  @doc """
  Returns the model selector list for `agent` as
  `{display_name, cli_model_value, premium_multiplier}` tuples.

  The curated/available models come first, followed by any additional models
  found in session history (deduplicated by model id and display name).
  """
  @spec for_agent(atom()) :: [{String.t(), String.t(), number()}]
  def for_agent(:claude), do: merge(@claude, used_models(:claude))
  def for_agent(:codex), do: merge(@codex, used_models(:codex))
  def for_agent(:gemini), do: merge(@gemini, used_models(:gemini))
  def for_agent(other), do: merge(Jido.GHCopilot.Models.all(), used_models(other))

  # ── Internal ──

  defp merge(curated, used_ids) do
    known_ids = MapSet.new(curated, &elem(&1, 1))
    known_names = MapSet.new(curated, fn {name, _, _} -> String.downcase(name) end)

    extras =
      used_ids
      |> Enum.reject(&MapSet.member?(known_ids, &1))
      |> Enum.filter(&model_id?/1)
      |> Enum.map(&{humanize(&1), &1, Jido.GHCopilot.Models.multiplier(&1)})
      |> Enum.reject(fn {name, _, _} -> MapSet.member?(known_names, String.downcase(name)) end)
      |> Enum.uniq_by(fn {name, _, _} -> String.downcase(name) end)
      |> Enum.sort_by(fn {name, _, _} -> String.downcase(name) end)

    curated ++ extras
  end

  # Only treat strings that contain a digit as real model ids. This filters out
  # provider/placeholder values such as "openai", "<synthetic>", or bare aliases
  # ("haiku") that are already covered by the curated lists.
  defp model_id?(id), do: is_binary(id) and Regex.match?(~r/\d/, id)

  defp event_model(data) when is_map(data) do
    map_get(data, "model") ||
      data |> map_get("data") |> map_get("model") ||
      data |> map_get("message") |> map_get("model") ||
      data |> map_get("data") |> map_get("message") |> map_get("model")
  end

  defp event_model(_data), do: nil

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp map_get(_map, _key), do: nil

  defp atom_key("model"), do: :model
  defp atom_key("data"), do: :data
  defp atom_key("message"), do: :message

  @doc false
  @spec humanize(String.t()) :: String.t()
  def humanize(id) do
    id
    |> String.split("-")
    |> Enum.reject(&date_token?/1)
    |> merge_version_tokens()
    |> Enum.map_join(" ", &humanize_token/1)
  end

  # 8-digit date stamp suffix, e.g. the "20251001" in "claude-haiku-4-5-20251001".
  defp date_token?(token), do: Regex.match?(~r/^\d{8}$/, token)

  defp humanize_token("gpt"), do: "GPT"

  defp humanize_token(token) do
    if version_token?(token), do: token, else: String.capitalize(token)
  end

  # Joins consecutive bare-integer tokens into a dotted version number so
  # "claude-opus-4-8" humanizes to "Claude Opus 4.8" (not "Claude Opus 4 8").
  defp merge_version_tokens(tokens) do
    tokens
    |> Enum.reduce([], fn token, acc ->
      case acc do
        [prev | rest] when is_binary(prev) ->
          if integer_token?(token) and version_token?(prev) do
            [prev <> "." <> token | rest]
          else
            [token | acc]
          end

        _ ->
          [token | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp integer_token?(token), do: Regex.match?(~r/^\d+$/, token)
  defp version_token?(token), do: Regex.match?(~r/^\d+(\.\d+)*$/, token)

  defp discover_used_models do
    sql = """
    SELECT agent, model FROM (
      SELECT agent AS agent, model AS model FROM sessions
        WHERE model IS NOT NULL AND model <> ''
      UNION
      SELECT s.agent AS agent, u.model AS model
        FROM usage_entries u
        JOIN sessions s ON s.id = u.session_id
        WHERE u.model IS NOT NULL AND u.model <> ''
      UNION
      SELECT s.agent AS agent,
             COALESCE(json_extract(e.data, '$.model'),
                      json_extract(e.data, '$.data.model'),
                      json_extract(e.data, '$.message.model'),
                      json_extract(e.data, '$.data.message.model')) AS model
        FROM events e
        JOIN sessions s ON s.id = e.session_id
        WHERE e.event_type NOT LIKE 'tool.%'
    )
    WHERE model IS NOT NULL AND model <> '' AND model <> '<synthetic>'
    GROUP BY agent, model
    """

    case CopilotLv.Repo.query(sql, []) do
      {:ok, %{rows: rows}} ->
        Enum.group_by(rows, fn [agent, _model] -> agent end, fn [_agent, model] -> model end)

      {:error, _reason} ->
        %{}
    end
  end
end
