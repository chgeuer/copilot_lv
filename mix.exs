defmodule CopilotLv.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/chgeuer/copilot_lv"

  def project do
    [
      app: :copilot_lv,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      description: "Phoenix LiveView dashboard for browsing AI coding agent sessions",
      source_url: @source_url,
      homepage_url: @source_url,
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => @source_url}
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {CopilotLv.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp jido_dep(name) do
    if System.get_env("USER") == "chgeuer" do
      [path: "/home/chgeuer/github/chgeuer/#{name}"]
    else
      [github: "chgeuer/#{name}"]
    end
  end

  defp agentjido_dep(name) do
    if System.get_env("USER") == "chgeuer" do
      [path: "/home/chgeuer/github/agentjido/#{name}"]
    else
      [github: "agentjido/#{name}"]
    end
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:jido_ghcopilot, jido_dep("jido_ghcopilot")},
      {:jido_pi, jido_dep("jido_pi")},
      {:jido_tool_renderers, jido_dep("jido_tool_renderers")},
      {:jido_sessions, jido_dep("jido_sessions")},
      {:jido_claude, agentjido_dep("jido_claude")},
      {:jido_codex, agentjido_dep("jido_codex")},
      {:jido_gemini, agentjido_dep("jido_gemini")},
      # Overrides for transitive deps not yet on hex or needing version alignment
      {:jido, "~> 2.1", override: true},
      {:jido_action, "~> 2.1", override: true},
      {:jido_signal, "~> 2.0", override: true},
      {:libgraph, "~> 0.16.1-mg.1", hex: :multigraph, override: true},
      {:jido_shell, agentjido_dep("jido_shell") ++ [override: true]},
      {:jido_harness, agentjido_dep("jido_harness") ++ [override: true]},
      {:jido_vfs, agentjido_dep("jido_vfs") ++ [override: true]},
      {:sprites, github: "mikehostetler/sprites-ex", override: true},
      {:ash, "~> 3.16"},
      {:ash_sqlite, "~> 0.2.15"},
      {:ash_phoenix, "~> 2.3"},
      {:yaml_elixir, "~> 2.11"},
      {:tidewave, "~> 0.5", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test]},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind copilot_lv", "esbuild copilot_lv"],
      "assets.deploy": [
        "tailwind copilot_lv --minify",
        "esbuild copilot_lv --minify",
        "phx.digest"
      ],
      # TODO: restore --warnings-as-errors once Ash type-checker warnings are resolved
      precommit: ["compile", "deps.unlock --unused", "format", "credo", "sobelow", "test"]
    ]
  end
end
