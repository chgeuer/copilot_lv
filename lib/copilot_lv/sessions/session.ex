defmodule CopilotLv.Sessions.Session do
  use Ash.Resource,
    domain: CopilotLv.Sessions,
    data_layer: AshSqlite.DataLayer

  @prefixes %{
    copilot: "gh",
    claude: "claude",
    codex: "codex",
    gemini: "gemini"
  }

  @doc "Build a prefixed session ID from agent type and provider-specific ID."
  def prefixed_id(agent_type, provider_id) when is_atom(agent_type) and is_binary(provider_id) do
    prefix = Map.fetch!(@prefixes, agent_type)
    "#{prefix}_#{provider_id}"
  end

  @doc "Extract the raw provider ID from a prefixed session ID."
  def provider_id(prefixed_id) when is_binary(prefixed_id) do
    case String.split(prefixed_id, "_", parts: 2) do
      [_prefix, id] -> id
      _ -> prefixed_id
    end
  end

  @doc "Extract the agent type atom from a prefixed session ID."
  def agent_from_id(prefixed_id) when is_binary(prefixed_id) do
    prefix_to_agent = Map.new(@prefixes, fn {k, v} -> {v, k} end)

    case String.split(prefixed_id, "_", parts: 2) do
      [prefix, _id] -> Map.get(prefix_to_agent, prefix)
      _ -> nil
    end
  end

  sqlite do
    table("sessions")
    repo(CopilotLv.Repo)
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false)
    attribute(:cwd, :string, allow_nil?: false)
    attribute(:model, :string)
    attribute(:summary, :string)
    attribute(:title, :string)
    attribute(:git_root, :string)
    attribute(:branch, :string)
    attribute(:copilot_version, :string)
    attribute(:event_count, :integer, default: 0)
    attribute(:hostname, :string)

    attribute(:agent, :atom,
      constraints: [one_of: [:copilot, :claude, :codex, :gemini]],
      default: :copilot
    )

    attribute(:config_dir, :string)

    attribute(:source, :atom,
      constraints: [one_of: [:live, :imported]],
      default: :live
    )

    attribute(:status, :atom,
      constraints: [one_of: [:starting, :idle, :thinking, :tool_running, :stopped]],
      default: :starting
    )

    attribute(:starred, :boolean, default: false)

    attribute(:started_at, :utc_datetime_usec, default: &DateTime.utc_now/0)
    attribute(:stopped_at, :utc_datetime_usec)
    attribute(:imported_at, :utc_datetime_usec)
  end

  relationships do
    has_many(:events, CopilotLv.Sessions.Event)
    has_many(:usage_entries, CopilotLv.Sessions.UsageEntry)
    has_many(:checkpoints, CopilotLv.Sessions.Checkpoint)
    has_many(:artifacts, CopilotLv.Sessions.SessionArtifact)
    has_many(:todos, CopilotLv.Sessions.SessionTodo)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:id, :cwd, :model, :hostname, :agent, :config_dir])
    end

    create :import do
      accept([
        :id,
        :cwd,
        :model,
        :summary,
        :title,
        :git_root,
        :branch,
        :copilot_version,
        :source,
        :status,
        :started_at,
        :stopped_at,
        :imported_at,
        :event_count,
        :hostname,
        :agent,
        :config_dir
      ])
    end

    update :update_status do
      accept([:status, :model, :stopped_at, :title])
    end

    update :update_import do
      accept([
        :summary,
        :title,
        :event_count,
        :imported_at,
        :hostname,
        :agent,
        :config_dir,
        :branch,
        :git_root,
        :model,
        :stopped_at
      ])
    end

    update :toggle_star do
      accept([:starred])
    end

    read :list_all do
      prepare(build(sort: [starred: :desc, started_at: :desc]))
    end

    read :active do
      filter(expr(status != :stopped))
    end

    read :imported do
      filter(expr(source == :imported))
      prepare(build(sort: [started_at: :desc]))
    end
  end
end
