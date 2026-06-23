defmodule KilnCMS.MixProject do
  use Mix.Project

  def project do
    [
      app: :kiln_cms,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: false
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {KilnCMS.Application, []},
      # `:image` (and its libvips NIF backend) is listed explicitly so it starts
      # and is included in the Dialyzer PLT.
      extra_applications: [:logger, :runtime_tools, :image]
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

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:oban, "~> 2.0"},
      {:ash_oban, "~> 0.8"},
      {:bcrypt_elixir, "~> 3.0"},
      {:picosat_elixir, "~> 0.2"},
      {:ash_authentication, "~> 4.0"},
      {:ash_authentication_phoenix, "~> 2.0"},
      {:absinthe_phoenix, "~> 2.0"},
      {:open_api_spex, "~> 3.0"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_archival, "~> 2.0"},
      {:ash_paper_trail, "~> 0.6"},
      {:ash_graphql, "~> 1.0"},
      {:ash_json_api, "~> 1.0"},
      {:ash_admin, "~> 1.0"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:igniter, "~> 0.5", only: [:dev, :test]},
      {:usage_rules, "~> 0.1", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:ash_phoenix, "~> 2.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:phoenix, "~> 1.8.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:html_sanitize_ex, "~> 1.4"},
      {:image, "~> 0.69"},
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},
      # Semantic search: pgvector storage + local embeddings (Bumblebee/Nx/EXLA).
      # The model + Nx.Serving only start when semantic search is enabled in
      # config; the deps compile regardless. See docs/semantic-search-plan.md.
      {:pgvector, "~> 0.3"},
      {:bumblebee, "~> 0.7"},
      {:nx, "~> 0.12"},
      {:exla, "~> 0.12"},
      # Bumblebee's `progress_bar` still caps `decimal ~> 2.0`, but Ash/ecto 3.14
      # need `decimal ~> 3.0`. progress_bar only uses decimal for CLI download
      # progress formatting, so forcing 3.x is safe. Override resolves the clash.
      {:decimal, "~> 3.0", override: true},
      {:hammer, "~> 7.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
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
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
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
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "cmd --cd assets npm install"
      ],
      "assets.build": ["compile", "tailwind kiln_cms", "esbuild kiln_cms"],
      "assets.deploy": [
        "tailwind kiln_cms --minify",
        "esbuild kiln_cms --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo --strict",
        "sobelow --config",
        "test"
      ]
    ]
  end
end
