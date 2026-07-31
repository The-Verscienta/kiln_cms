defmodule KilnCMS.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/The-Verscienta/kiln_cms"

  def project do
    [
      app: :kiln_cms,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      # Never let `gettext.merge` copy a translation between non-identical
      # msgids. Its fuzzy matcher is Jaro distance on the msgid, and at the
      # 0.8 default our short UI strings collide constantly — "Site name" was
      # matched to "Set name" and inherited its Spanish ("Establecer nombre"),
      # "Powered by %{name}." inherited "Se restauró %{name}." ("It was
      # restored"). Those land as *confident, wrong* translations that read as
      # already-done work, which is worse than no translation at all.
      #
      # 1.0 means "only match identical msgids", and identical msgids are
      # already handled as exact matches before fuzzy is tried — so this
      # effectively turns fuzzy off. A new msgid now gets an empty msgstr and
      # falls back to English, which the untranslated-msgid CI check catches.
      # (`--no-fuzzy` does the same but is CLI-only; this applies to every
      # invocation, including someone running the bare command locally.)
      gettext: [fuzzy_threshold: 1.0],
      consolidate_protocols: Mix.env() != :dev,
      name: "KilnCMS",
      source_url: @source_url,
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: false
      ]
    ]
  end

  # `mix docs` — the ExDoc API reference plus every human guide under `docs/`.
  # Build with `mix docs` and open `doc/index.html`; the landing page is the
  # onboarding guide, `docs/getting-started.md`.
  defp docs do
    [
      main: "getting-started",
      # HTML only. Nothing consumes the EPUB, and building it doubles both the
      # run time and every warning the docs gate reports.
      formatters: ["html"],
      # There are no release tags yet, so ExDoc's default `source_ref` of
      # "v#{version}" would 404 on every "View Source" link. Point at `main`
      # until `docs/releasing.md` actually cuts a tag.
      source_ref: "main",
      nest_modules_by_prefix: [KilnCMS, KilnCMSWeb, Kiln],
      # Two exclusions:
      #
      #   * `elixirc_paths` compiles `projects/` alongside `lib/`, so a
      #     downstream overlay's modules land in the same build. They are not
      #     part of the reusable core and must not appear in its reference.
      #   * Macro-generated subscription config modules arrive as bare atoms
      #     (`:"PageChanged.Config"`) with no `Elixir.` prefix. Requiring that
      #     prefix keeps generated internals out of the sidebar.
      filter_modules: fn module, _metadata ->
        name = Atom.to_string(module)

        String.starts_with?(name, "Elixir.") and
          not String.starts_with?(name, "Elixir.Acupuncture.")
      end,
      # Real code that is deliberately not part of the documented surface —
      # `@moduledoc false` internals, generated modules, Phoenix/Oban callbacks.
      # Naming them in prose is correct and useful; ExDoc just has nothing to
      # link them to. Listing them here keeps `--warnings-as-errors` meaningful
      # instead of blanket-suppressing warnings for whole files.
      skip_code_autolink_to: [
        "KilnCMS.Application",
        "KilnCMS.PostgrexTypes",
        "KilnCMS.Repo.installed_extensions/0",
        "KilnCMSWeb.Telemetry.init/1",
        "KilnCMSWeb.AuthController.success/4",
        "Oban.Worker.timeout/1",
        # Named by `projects/README.md` as the worked overlay example, and
        # excluded from the reference by `filter_modules` above.
        "Acupuncture.Catalog"
      ],
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules()
    ]
  end

  # Every guide is listed, including the point-in-time ones. What keeps the
  # sidebar honest is *where* they land — see `groups_for_extras/0`, which
  # files audits and one-shot deploy checklists under an archive heading rather
  # than alongside standing operator guidance.
  #
  # `title:` is only overridden where a document's H1 carries internal phase
  # numbering that would otherwise read as part of the feature's name.
  # `filename:` is required wherever two extras share a basename (README).
  defp extras do
    [
      # Getting started
      "docs/getting-started.md": [],
      "README.md": [title: "Overview"],
      "CONTRIBUTING.md": [],
      # Authoring & editorial
      "docs/editor-shortcuts.md": [],
      "docs/advisories.md": [],
      "docs/forms.md": [],
      "docs/seo.md": [],
      "docs/ai-assist.md": [],
      "docs/geo.md": [],
      "docs/multiplayer-preview.md": [],
      "docs/editorial-consent.md": [],
      "docs/governance-dashboard.md": [],
      "docs/localization-workflows.md": [],
      "docs/automation.md": [],
      "docs/newsletter.md": [title: "Newsletter"],
      "docs/memberships.md": [title: "Paid memberships"],
      "docs/provenance.md": [],
      "docs/point-in-time.md": [],
      # Modeling & extending
      "docs/extending-content.md": [],
      "docs/design-system.md": [],
      "docs/plugin-extensibility.md": [],
      "docs/frontend-assets.md": [],
      # APIs & headless
      "docs/api.md": [],
      "docs/headless-consumer-guide.md": [],
      "docs/json-api.md": [],
      "docs/headless-graphql-api.md": [],
      "docs/mcp.md": [],
      "docs/rag.md": [],
      "docs/visual-editing-bridge.md": [],
      "docs/static-export.md": [],
      "docs/resilient-delivery.md": [],
      # Search
      "docs/meilisearch.md": [title: "Meilisearch backend"],
      # Operations & deployment
      "docs/environment-variables.md": [],
      "docs/backups.md": [],
      "docs/observability.md": [],
      "docs/performance.md": [],
      "docs/releasing.md": [],
      "docs/staging-environments.md": [],
      "docs/media-pipeline.md": [],
      "docs/direct-email-delivery.md": [],
      "docs/data-flows.md": [],
      # Security & access
      "docs/policy-matrix.md": [],
      "docs/granular-rbac.md": [],
      "docs/passkeys.md": [],
      "docs/two-factor-auth.md": [],
      "docs/sso.md": [],
      "docs/threat-model.md": [],
      # Design notes & decision records
      "docs/advanced-analytics-plan.md": [],
      "docs/collaborative-editing-spike.md": [],
      "docs/content-editor-modernization.md": [],
      "docs/design-language.md": [],
      "docs/dynamic-content-types-plan.md": [],
      "docs/form-builder-plan.md": [],
      "docs/plugin-system-plan.md": [],
      "docs/search-roadmap.md": [],
      "docs/search-tsvector-migration.md": [],
      "docs/semantic-search-plan.md": [],
      "docs/direct-email-delivery-plan.md": [],
      "docs/kiln-v2-implementation-guide.md": [],
      "docs/competitive-gaps-todo.md": [],
      "docs/differentiator-opportunities.md": [],
      "docs/cms-comparison.md": [],
      "docs/p3-plan.md": [],
      # Audits & release checklists
      "docs/audit-2026-07-full-surface.md": [],
      "docs/audit-2026-07-performance-usability.md": [],
      "docs/deploy-p2.md": [],
      "docs/deploy-p3.md": [],
      "docs/deploy-staging.md": [],
      "docs/deploy-write-visual-editing.md": [],
      # Project history
      "CHANGELOG.md": [],
      "KilnCMS_Project_Plan.md": [title: "Project plan"],
      "kiln-cms-plan-v2.md": [title: "Kiln v2 plan"],
      # AGENTS.md is deliberately NOT an extra. It is coding-agent instructions
      # rather than guide material, and the `usage_rules` blocks it carries link
      # into `deps/**/usage-rules.md` — ~110 references that resolve in a checkout
      # but not in generated docs, which would drown every real warning.
      "examples/README.md": [title: "Examples", filename: "examples-readme"],
      "projects/README.md": [title: "Downstream projects", filename: "projects-readme"],
      "clients/elixir/kiln_client/README.md": [
        title: "Elixir client",
        filename: "elixir-client-readme"
      ]
    ]
  end

  defp groups_for_extras do
    [
      "Getting started": ["docs/getting-started.md", "README.md", "CONTRIBUTING.md"],
      "Authoring & editorial": [
        "docs/editor-shortcuts.md",
        "docs/advisories.md",
        "docs/forms.md",
        "docs/seo.md",
        "docs/ai-assist.md",
        "docs/geo.md",
        "docs/multiplayer-preview.md",
        "docs/editorial-consent.md",
        "docs/governance-dashboard.md",
        "docs/localization-workflows.md",
        "docs/automation.md",
        "docs/newsletter.md",
        "docs/memberships.md",
        "docs/provenance.md",
        "docs/point-in-time.md"
      ],
      "Modeling & extending": [
        "docs/extending-content.md",
        "docs/design-system.md",
        "docs/plugin-extensibility.md",
        "docs/frontend-assets.md"
      ],
      "APIs & headless": [
        "docs/api.md",
        "docs/headless-consumer-guide.md",
        "docs/json-api.md",
        "docs/headless-graphql-api.md",
        "docs/mcp.md",
        "docs/rag.md",
        "docs/visual-editing-bridge.md",
        "docs/static-export.md",
        "docs/resilient-delivery.md"
      ],
      Search: ["docs/meilisearch.md"],
      "Operations & deployment": [
        "docs/environment-variables.md",
        "docs/backups.md",
        "docs/observability.md",
        "docs/performance.md",
        "docs/releasing.md",
        "docs/staging-environments.md",
        "docs/media-pipeline.md",
        "docs/direct-email-delivery.md",
        "docs/data-flows.md"
      ],
      "Security & access": [
        "docs/policy-matrix.md",
        "docs/granular-rbac.md",
        "docs/passkeys.md",
        "docs/two-factor-auth.md",
        "docs/sso.md",
        "docs/threat-model.md"
      ],
      "Design notes & decision records": [
        "docs/advanced-analytics-plan.md",
        "docs/collaborative-editing-spike.md",
        "docs/content-editor-modernization.md",
        "docs/design-language.md",
        "docs/dynamic-content-types-plan.md",
        "docs/form-builder-plan.md",
        "docs/plugin-system-plan.md",
        "docs/search-roadmap.md",
        "docs/search-tsvector-migration.md",
        "docs/semantic-search-plan.md",
        "docs/direct-email-delivery-plan.md",
        "docs/kiln-v2-implementation-guide.md",
        "docs/competitive-gaps-todo.md",
        "docs/differentiator-opportunities.md",
        "docs/cms-comparison.md",
        "docs/p3-plan.md"
      ],
      "Audits & release checklists": [
        "docs/audit-2026-07-full-surface.md",
        "docs/audit-2026-07-performance-usability.md",
        "docs/deploy-p2.md",
        "docs/deploy-p3.md",
        "docs/deploy-staging.md",
        "docs/deploy-write-visual-editing.md"
      ],
      "Project history": [
        "CHANGELOG.md",
        "KilnCMS_Project_Plan.md",
        "kiln-cms-plan-v2.md",
        "examples/README.md",
        "projects/README.md",
        "clients/elixir/kiln_client/README.md"
      ]
    ]
  end

  # Ordered: a module joins the first group it matches, so the catch-all
  # `KilnCMSWeb` entry has to come last. The `^(Elixir\.)?` prefix makes each
  # pattern independent of how ExDoc spells the module name.
  defp groups_for_modules do
    [
      "Extension points": ~r/^(Elixir\.)?Kiln\./,
      "Content model": ~r/^(Elixir\.)?KilnCMS\.(CMS|Blocks|Forms|Slug)(\.|$)/,
      "Accounts & authorization": ~r/^(Elixir\.)?KilnCMS\.(Accounts|Keys)(\.|$)/,
      "Search & retrieval": ~r/^(Elixir\.)?KilnCMS\.(Search|SearchIndex|Ask)(\.|$)/,
      "Media & storage": ~r/^(Elixir\.)?KilnCMS\.(Media|Storage|ImageProcessor|Unsplash)(\.|$)/,
      "Email & notifications":
        ~r/^(Elixir\.)?KilnCMS\.(Mail|Mailer|Newsletter|Notifications)(\.|$)/,
      "Editorial operations":
        ~r/^(Elixir\.)?KilnCMS\.(Governance|History|Provenance|Automation|Webhooks|Staging|Collab)(\.|$)/,
      "Rendering & delivery":
        ~r/^(Elixir\.)?KilnCMS\.(Firing|HTMLSanitizer|Highlight|VisualEditing|Seo|Assist|LLM|Branding|I18n)(\.|$)/,
      Analytics: ~r/^(Elixir\.)?KilnCMS\.Analytics(\.|$)/,
      "Runtime & infrastructure":
        ~r/^(Elixir\.)?KilnCMS\.(Application|Cache|Migrations|Release|Repo|Secrets|SentryFilter)(\.|$)/,
      "Web — LiveViews": ~r/^(Elixir\.)?KilnCMSWeb\..*Live$/,
      "Web — components & templates":
        ~r/^(Elixir\.)?KilnCMSWeb\.(.*Components|.*HTML|.*JSON|Layouts)$/,
      "Web — controllers, plugs & channels":
        ~r/^(Elixir\.)?KilnCMSWeb\.(.*Controller|.*Channel|.*Socket|.*Router|Plugs\..*|Endpoint)$/,
      "Web — support": ~r/^(Elixir\.)?KilnCMSWeb(\.|$)/
      # No entry for `Mix.Tasks.Kiln.*` — ExDoc lifts mix tasks into their own
      # top-level "Mix Tasks" section, so a group here would never match.
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
      # MCP server for LLM authoring (write-scoped API keys) — see docs/mcp.md.
      {:ash_ai, "~> 0.7"},
      # Provider-agnostic LLM client behind the optional SEO drafting generator
      # (docs/seo.md). Declared directly rather than leaned on as an `ash_ai`
      # transitive: a minor bump there could make it optional and break us.
      {:req_llm, "~> 1.17"},
      {:ash_admin, "~> 1.0"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:igniter, "~> 0.5", only: [:dev, :test]},
      {:usage_rules, "~> 0.1", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      # Dev only, and `mix docs` must be run under MIX_ENV=dev. Under `:test`,
      # `elixirc_paths` also compiles `test/support`, which puts `DataCase`,
      # the `Stub*` doubles and the fixture plugin into the published reference.
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
      {:corsica, "~> 2.1"},
      {:html_sanitize_ex, "~> 1.4"},
      # Fire-time syntax highlighting for rich-text code blocks (#503). Each
      # lexer is its own OTP app that registers language names with
      # Makeup.Registry on boot — see KilnCMS.Highlight.
      {:makeup, "~> 1.2"},
      {:makeup_elixir, "~> 1.0"},
      {:makeup_erlang, "~> 1.0"},
      {:makeup_eex, "~> 2.0"},
      # makeup_ts registers both the "js"/"javascript" and "ts"/"typescript"
      # names, so a separate makeup_js would only fight it for the registry.
      {:makeup_ts, "~> 0.2"},
      {:makeup_html, "~> 0.2"},
      {:makeup_json, "~> 1.0"},
      {:makeup_css, "~> 0.2"},
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
      # WebAuthn/passkey ceremony verification (#331) — attestation and
      # assertion checks for the first-party passkey strategy.
      {:wax_, "~> 0.7"},
      # QR code SVG for TOTP enrolment (#331) — pure Elixir, no NIF.
      {:eqrcode, "~> 0.2"},
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
        "deps.audit",
        "kiln.plugins.doctor",
        # Cheap, and catches a class nothing else can: CI never builds the
        # release image, so a Dockerfile pin that can't satisfy this file's
        # `elixir:` requirement is green everywhere until a deploy fails (#600).
        "kiln.toolchain.check",
        # Catches untranslated/fuzzy msgstrs locally. Read-only, so `precommit`
        # keeps its non-destructive contract — the *drift* half of the gate
        # still lives in CI only, because `gettext.extract --merge` rewrites
        # priv/gettext. Run that yourself before pushing.
        "kiln.gettext.check",
        "test"
      ]
    ]
  end
end
