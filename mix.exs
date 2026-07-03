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
      preferred_envs: [
        precommit: :test,
        "e2e.setup": :e2e,
        "e2e.reset": :e2e
      ]
    ]
  end

  # Specifies which paths to compile per environment. `projects/` holds
  # project-specific subprojects (content catalogs, importers) layered on the
  # reusable core in `lib/`.
  defp elixirc_paths(:test), do: ["lib", "projects", "test/support"]
  defp elixirc_paths(_), do: ["lib", "projects"]

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
      # Yjs CRDTs on the BEAM (collab-editing prototype — see the spike doc).
      {:y_ex, "~> 0.10.5"},
      {:phoenix, "~> 1.8.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:html_sanitize_ex, "~> 1.4"},
      {:cachex, "~> 4.0"},
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
      # EXLA compiles a heavy XLA NIF from source (~13 min, multi-GB RAM) and
      # pulls the :xla archive — too much for the small prod build host. Keep it
      # for local dev/test speed; prod/e2e fall back to Nx.BinaryBackend (see
      # config/dev.exs + test.exs). Semantic search is disabled by default in
      # prod; restore EXLA there via an off-box image build before enabling it.
      {:exla, "~> 0.12", only: [:dev, :test]},
      # Bumblebee's `progress_bar` still caps `decimal ~> 2.0`, but Ash/ecto 3.14
      # need `decimal ~> 3.0`. progress_bar only uses decimal for CLI download
      # progress formatting, so forcing 3.x is safe. Override resolves the clash.
      {:decimal, "~> 3.0", override: true},
      {:hammer, "~> 7.0"},
      {:remote_ip, "~> 1.2"},
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
      # Required by Swoosh.Adapters.SMTP, the production mailer adapter (config/runtime.exs).
      {:gen_smtp, "~> 1.0"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      # Error tracking. No-op unless SENTRY_DSN is set (config/runtime.exs), so
      # dev/test/precommit stay offline. Uses Req (not hackney) for transport to
      # keep the project on a single HTTP client — see KilnCMS.SentryReqClient.
      {:sentry, "~> 13.2"},
      # Distributed tracing (OpenTelemetry). Spans are only exported when
      # OTEL_EXPORTER_OTLP_ENDPOINT is set (config/runtime.exs); otherwise the
      # instrumentation is never attached. See KilnCMS.Application.setup_otel/0
      # and docs/observability.md.
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.10"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_bandit, "~> 0.3"},
      {:opentelemetry_oban, "~> 1.2"},
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
      # Browser E2E (MIX_ENV=e2e). `e2e.setup` builds assets and prepares the DB
      # + demo seeds; the server itself is then started in a *separate* VM with
      # `PHX_SERVER=true mix phx.server` (see e2e/playwright.config.js). It can't
      # be one alias: `mix run seeds.exs` halts the VM, so a trailing
      # `phx.server` in the same chain would never run.
      "e2e.setup": [
        "assets.setup",
        "assets.build",
        "ash.setup --quiet",
        "run priv/repo/seeds.exs"
      ],
      "e2e.reset": ["ecto.drop --quiet", "e2e.setup"],
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
