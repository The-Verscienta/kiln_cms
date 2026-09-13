# The optional ML stack (#1321) is decided before anything else in this file:
# `deps/0` below reads it to leave Bumblebee/Nx/EXLA out of the tree entirely
# unless `KILN_ML` is on, and `config/dev.exs` + `config/test.exs` require the
# same snippet for the same answer. See `config/ml_flag.exs` for why the flag
# lives in a standalone `.exs` and not in `lib/`.
Code.require_file(Path.expand("config/ml_flag.exs", __DIR__))

defmodule KilnCMS.MixProject do
  use Mix.Project

  @version "0.8.0"
  @source_url "https://github.com/The-Verscienta/kiln_cms"

  def project do
    [
      # Gettext catalogs are generated files that nearly every PR touches, so
      # their *format* decides how often two PRs collide. Two settings do the
      # work, and both were measured rather than guessed — a five-line shift in
      # `content_editor_live.ex` churned 3,296 catalog lines before this, and 0
      # after; two PRs adding unrelated strings conflicted before, and merge
      # cleanly after.
      #
      #   * `write_reference_line_numbers: false` — a `#: lib/foo.ex:8777`
      #     comment changes whenever any line above it moves, so an edit
      #     rewrites entries it has nothing to do with. That is what made every
      #     open PR conflict on every merge, and what made even a conflict-free
      #     merge fail the drift gate. The file name is kept: it is the part
      #     anyone reads, and it changes only when a string really moves file.
      #
      #   * `sort_by_msgid: :case_sensitive` — without it new messages are
      #     appended in source-walk order, so where a string lands depends on
      #     which file it came from. Sorted, two PRs adding unrelated strings
      #     touch different regions of the file.
      #
      # Read from `Mix.Project.config()[:gettext]` — a `config :gettext, …` in
      # `config/config.exs` is silently ignored, which costs an hour to notice.
      #
      # This must be a SINGLE `gettext:` key in this list — `Mix.Project.config()`
      # is a keyword list, and a second `gettext:` key added later is silently
      # shadowed (the first match wins), so its options never take effect. All
      # gettext options belong here.
      gettext: [
        write_reference_line_numbers: false,
        sort_by_msgid: :case_sensitive,
        fuzzy_threshold: 1.0
      ],
      app: :kiln_cms,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      # `mix coveralls.*` (#1314) — floor and skip list in coveralls.json.
      test_coverage: [tool: ExCoveralls],
      # `fuzzy_threshold: 1.0` above (in the `gettext:` key near the top of this
      # list) exists to never let `gettext.merge` copy a translation between
      # non-identical msgids. Its fuzzy matcher is Jaro distance on the msgid,
      # and at the 0.8 default our short UI strings collide constantly —
      # "Site name" was matched to "Set name" and inherited its Spanish
      # ("Establecer nombre"), "Powered by %{name}." inherited "Se restauró
      # %{name}." ("It was restored"). Those land as *confident, wrong*
      # translations that read as already-done work, which is worse than no
      # translation at all.
      #
      # 1.0 means "only match identical msgids", and identical msgids are
      # already handled as exact matches before fuzzy is tried — so this
      # effectively turns fuzzy off. A new msgid now gets an empty msgstr and
      # falls back to English, which the untranslated-msgid CI check catches.
      # (`--no-fuzzy` does the same but is CLI-only; this applies to every
      # invocation, including someone running the bare command locally.)
      consolidate_protocols: Mix.env() != :dev,
      name: "KilnCMS",
      source_url: @source_url,
      docs: docs(),
      dialyzer: [
        # :excoveralls is `runtime: false`, so it is not in the PLT by default —
        # and `mix kiln.coverage.merge` (test/support) calls it directly.
        plt_add_apps: [:mix, :ex_unit, :excoveralls],
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
      # "View Source" links are only useful if they point at an immutable ref.
      # A branch is not one: links built from `main` keep resolving as the
      # branch moves, so a published build eventually points at a shifted line
      # or a function that no longer exists. Point at this version's release
      # tag — `@version` is bumped to match the tag in the release commit
      # (see `docs/releasing.md`), so a docs build of a release resolves to
      # exactly the code it documents.
      #
      # A build from an untagged mid-cycle `main` is the case the tag cannot
      # cover: `@version` there still names the *previous* release, whose tag
      # predates the code being documented. Pin such a build to its own commit
      # with `DOCS_SOURCE_REF=$(git rev-parse HEAD) mix docs`.
      source_ref: System.get_env("DOCS_SOURCE_REF", "v#{@version}"),
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
          not String.starts_with?(name, "Elixir.Example.")
      end,
      # Real code that is deliberately not part of the documented surface —
      # `@moduledoc false` internals, generated modules, Phoenix/Oban callbacks.
      # Naming them in prose is correct and useful; ExDoc just has nothing to
      # link them to. Listing them here keeps `--warnings-as-errors` meaningful
      # instead of blanket-suppressing warnings for whole files.
      skip_code_autolink_to: [
        # Hidden (LiveView renders carry @doc false) — the inspector components'
        # moduledocs cite it as the code's provenance (#1311).
        "KilnCMSWeb.ContentEditorLive.render/1",
        "KilnCMS.Application",
        "KilnCMS.Application.start/2",
        "KilnCMS.Governance.Chain.any_history_anchors?/0",
        # Private — VectorCache's moduledoc names the caller that decides
        # whether a raw-cache hit is free (#1076).
        "KilnCMS.Search.Related.unindexed_centroid/2",
        "KilnCMS.PostgrexTypes",
        "KilnCMS.Repo.installed_extensions/0",
        "KilnCMSWeb.Telemetry.init/1",
        "KilnCMSWeb.AuthController.success/4",
        "Oban.Worker.timeout/1",
        "Oban.Cron.Expression",
        # Named by `projects/README.md` as the worked overlay example, and
        # excluded from the reference by `filter_modules` above.
        "Example.Catalog",
        "Example.Plugin",
        # Behaviour callbacks (`@impl true`, so ExDoc hides them). Both are
        # named by `docs/semantic-search-plan.md` and `KilnCMS.Search.ML`,
        # which have to say which functions return
        # `%KilnCMS.Search.ML.NotCompiledError{}` in a lean build (#1321) —
        # naming them is the point, and there is nothing to link them to.
        "KilnCMS.Search.Embedder.Bumblebee.embed/1",
        "KilnCMS.Search.Reranker.Bumblebee.scores/2",
        # A dependency's module, marked `@moduledoc false` upstream. Naming it
        # is correct and useful — `KilnCMS.CMS.Calculations.RelatedLinks`
        # explains a real behaviour of it — but ExDoc has nothing to link a
        # hidden module to, and the docs gate runs `--warnings-as-errors`.
        "AshAi.Serializer",
        # A dependency function named for the #1172 hold contract's own
        # explanation of why it works — ExDoc does not index AshAuthentication's
        # docs from this project.
        "AshAuthentication.Plug.Helpers.validate_token/3",
        # Private — named by FormSettingsLive's moduledoc for the contradiction
        # rule it mirrors, not something callers outside FormBuilderLive reach.
        "KilnCMSWeb.FormBuilderLive.form_params/1",
        # CHANGELOG history for the 0.6.0 release, naming the function under
        # the name it had at the time (#1171 later renamed it to
        # `mint_and_hold/4`). Historical entries describe the past, not the
        # current surface, and must not be rewritten to keep this passing.
        "KilnCMS.Accounts.PendingSignIn.mint/4",
        # Private — LiveJoinBudget's moduledoc names the reason
        # SignInLive.charge_here?/1 gives for the same connected-root-only
        # shape, not something callers outside SignInLive reach.
        "KilnCMSWeb.SignInLive.charge_here?/1",
        # A Phoenix dependency module with no public docs of its own — named
        # for what it does with a 4xx raised during mount, not something
        # ExDoc can link to.
        "Phoenix.LiveView.Channel",
        # CHANGELOG entry for the #599 family xmerl dialyzer fix, naming the
        # opaque Erlang/Elixir types the fix works around. ExDoc autolinks
        # code-formatted references inside extras (CHANGELOG.md included), and
        # neither is a KilnCMS module ExDoc can resolve.
        ":sets.set/1",
        "MapSet.t/1"
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
  #
  # **A shared basename makes relative links to those files unwritable.** ExDoc
  # resolves a relative link from one extra to another by basename and nothing
  # else — `ExDoc.Formatter.extra_paths/1` is a `Map.put(acc,
  # Path.basename(source_path), id)` folded over this list in order, and
  # `ExDoc.Autolink.build_extra_link/2` looks a link up as
  # `config.extras[Path.basename(path)]`. The directories in the link are never
  # consulted, and `filename:` renames the *output* page without affecting this
  # lookup. So every relative link to any of the four README extras below
  # resolved to whichever is registered last — ten links written as
  # `../README.md`, `../projects/README.md` or `../examples/README.md` rendered
  # as links to the Elixir client's page.
  #
  # `--warnings-as-errors` does not catch it: ExDoc warns when a basename is
  # absent from that map, not when it is present and wrong. The docs job stayed
  # green for as long as the links were wrong.
  #
  # Link a README by its full
  # `https://github.com/The-Verscienta/kiln_cms/blob/main/…` URL instead —
  # correct both on github.com and in the generated docs.
  # `test/kiln_cms/docs/extras_links_test.exs` fails the build if a relative link
  # between extras renders as a link to a different file than it names, for
  # README and for any basename that collides later. Reordering this list is not
  # a fix: it only changes which of the colliding links is wrong.
  defp extras do
    [
      # Getting started
      "docs/getting-started.md": [],
      "README.md": [title: "Overview"],
      "CONTRIBUTING.md": [],
      # Authoring & editorial
      "docs/editor-shortcuts.md": [],
      "docs/markdown.md": [],
      "docs/advisories.md": [],
      "docs/compliance.md": [],
      "docs/link-checking.md": [],
      "docs/comments.md": [],
      "docs/content-releases.md": [],
      "docs/content-lifecycles.md": [],
      "docs/working-copy.md": [],
      "docs/forms.md": [],
      "docs/seo.md": [],
      "docs/ai-assist.md": [],
      "docs/geo.md": [],
      "docs/multiplayer-preview.md": [],
      "docs/editorial-consent.md": [],
      "docs/governance-dashboard.md": [],
      "docs/localization-workflows.md": [],
      "docs/navigation-menus.md": [],
      "docs/public-theming.md": [],
      "docs/automation.md": [],
      "docs/newsletter.md": [title: "Newsletter"],
      "docs/memberships.md": [title: "Paid memberships"],
      "docs/provenance.md": [],
      "docs/federation.md": [],
      "docs/chain-fold-order.md": [],
      "docs/social-posting.md": [],
      "docs/point-in-time.md": [],
      # Modeling & extending
      "docs/overlay-contract.md": [title: "The overlay contract"],
      "docs/extending-content.md": [],
      "docs/events.md": [title: "Events"],
      "docs/design-language.md": [],
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
      "docs/webhooks.md": [],
      # Search
      "docs/meilisearch.md": [title: "Meilisearch backend"],
      # Operations & deployment
      "docs/deploy.md": [],
      "docs/environment-variables.md": [],
      "docs/backups.md": [],
      "docs/observability.md": [],
      "docs/performance.md": [],
      "docs/releasing.md": [],
      "docs/beta-testing.md": [],
      "docs/staging-environments.md": [],
      "docs/demo-mode.md": [],
      "docs/media-pipeline.md": [],
      "docs/content-portability.md": [],
      "docs/direct-email-delivery.md": [],
      "docs/data-flows.md": [],
      # Security & access
      "docs/policy-matrix.md": [],
      "docs/code-injection.md": [],
      "docs/granular-rbac.md": [],
      "docs/multi-tenancy.md": [],
      "docs/passkeys.md": [],
      "docs/two-factor-auth.md": [],
      "docs/sso.md": [],
      "docs/threat-model.md": [],
      # Design notes & decision records
      "docs/advanced-analytics-plan.md": [],
      "docs/collaborative-editing-spike.md": [],
      "docs/content-editor-modernization.md": [],
      "docs/dynamic-content-types-plan.md": [],
      "docs/form-builder-plan.md": [],
      "docs/content-experiments-plan.md": [],
      "docs/mobile-admin-spike.md": [],
      "docs/plugin-system-plan.md": [],
      "docs/plugin-registry-plan.md": [],
      "docs/search-roadmap.md": [],
      "docs/search-tsvector-migration.md": [],
      "docs/semantic-search-plan.md": [],
      "docs/direct-email-delivery-plan.md": [],
      "docs/test-coverage-plan.md": [],
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
        "docs/markdown.md",
        "docs/advisories.md",
        "docs/compliance.md",
        "docs/link-checking.md",
        "docs/comments.md",
        "docs/content-releases.md",
        "docs/content-lifecycles.md",
        "docs/working-copy.md",
        "docs/forms.md",
        "docs/seo.md",
        "docs/ai-assist.md",
        "docs/geo.md",
        "docs/multiplayer-preview.md",
        "docs/editorial-consent.md",
        "docs/governance-dashboard.md",
        "docs/code-injection.md",
        "docs/localization-workflows.md",
        "docs/navigation-menus.md",
        "docs/public-theming.md",
        "docs/automation.md",
        "docs/newsletter.md",
        "docs/memberships.md",
        "docs/provenance.md",
        "docs/federation.md",
        "docs/social-posting.md",
        "docs/point-in-time.md",
        "docs/chain-fold-order.md"
      ],
      "Modeling & extending": [
        "docs/overlay-contract.md",
        "docs/extending-content.md",
        "docs/events.md",
        "docs/design-language.md",
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
        "docs/resilient-delivery.md",
        "docs/webhooks.md"
      ],
      Search: ["docs/meilisearch.md"],
      "Operations & deployment": [
        "docs/deploy.md",
        "docs/environment-variables.md",
        "docs/backups.md",
        "docs/observability.md",
        "docs/performance.md",
        "docs/releasing.md",
        "docs/beta-testing.md",
        "docs/staging-environments.md",
        "docs/demo-mode.md",
        "docs/media-pipeline.md",
        "docs/content-portability.md",
        "docs/direct-email-delivery.md",
        "docs/data-flows.md"
      ],
      "Security & access": [
        "docs/policy-matrix.md",
        "docs/granular-rbac.md",
        "docs/multi-tenancy.md",
        "docs/passkeys.md",
        "docs/two-factor-auth.md",
        "docs/sso.md",
        "docs/threat-model.md"
      ],
      "Design notes & decision records": [
        "docs/advanced-analytics-plan.md",
        "docs/collaborative-editing-spike.md",
        "docs/content-editor-modernization.md",
        "docs/dynamic-content-types-plan.md",
        "docs/form-builder-plan.md",
        "docs/content-experiments-plan.md",
        "docs/mobile-admin-spike.md",
        "docs/plugin-system-plan.md",
        "docs/plugin-registry-plan.md",
        "docs/search-roadmap.md",
        "docs/search-tsvector-migration.md",
        "docs/semantic-search-plan.md",
        "docs/direct-email-delivery-plan.md",
        "docs/test-coverage-plan.md",
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
        ~r/^(Elixir\.)?KilnCMS\.(Governance|History|Provenance|Automation|Webhooks|Staging|Collab|Beta)(\.|$)/,
      "Rendering & delivery":
        ~r/^(Elixir\.)?KilnCMS\.(Firing|HTMLSanitizer|Highlight|VisualEditing|Seo|Assist|LLM|Branding|I18n)(\.|$)/,
      Analytics: ~r/^(Elixir\.)?KilnCMS\.Analytics(\.|$)/,
      "Runtime & infrastructure":
        ~r/^(Elixir\.)?KilnCMS\.(Application|Cache|Config|Migrations|Release|Repo|Secrets|SentryFilter)(\.|$)/,
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
        # Every reporter excoveralls ships, not just the two CI uses: the dep is
        # `only: :test`, so any one of them started in :dev fails on a missing
        # module rather than on anything a reader could act on.
        coveralls: :test,
        "coveralls.cobertura": :test,
        "coveralls.detail": :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.lcov": :test,
        "coveralls.multiple": :test,
        "coveralls.post": :test,
        "coveralls.xml": :test,
        "kiln.coverage.summary": :test,
        # Lives in test/support (it calls excoveralls, an `only: :test` dep),
        # so it exists only in this env — see its moduledoc.
        "kiln.coverage.merge": :test,
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
      # Line coverage (#1314). `mix coveralls.*` wraps `mix test --cover`; the
      # floor and skip list live in coveralls.json, the CI wiring in
      # .github/workflows/ci.yml, the per-directory rollup in
      # `mix kiln.coverage.summary`.
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
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
      # Reads legacy HTML back into structured prose for the importers (#487):
      # a WordPress body is a blob of HTML, and Portable Text is the only shape
      # this CMS stores. Backed by mochiweb (already here through
      # html_sanitize_ex) rather than a NIF, so it adds no build weight.
      {:floki, "~> 0.38"},
      # Markdown → structured content (`KilnCMS.Markdown`): editor paste, `.md`
      # import, and the `body_markdown` API argument. The PARSER only, and pure
      # Elixir — the one ex_doc already uses, now needed at runtime. Not
      # `earmark`: that package is retired on Hex, carries a stored-XSS advisory
      # in its HTML renderer, and would fail `mix deps.audit`. Its AST is
      # rendered to HTML by `KilnCMS.Markdown` itself, from a closed tag list
      # with every text run and attribute escaped, and the result is sanitized
      # on the way into storage even then — see that module.
      {:earmark_parser, "~> 1.4"},
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
      # Semantic search's STORAGE half: the pgvector column type and its
      # Postgrex extension. Cheap, pure Elixir, and unconditional —
      # `KilnCMS.Repo.installed_extensions/0` requires the `vector` extension
      # whether or not anything embeds, so this is not part of the optional ML
      # stack below (see `ml_deps/0`).
      {:pgvector, "~> 0.3"},
      # Bumblebee's `progress_bar` still caps `decimal ~> 2.0`, but Ash/ecto 3.14
      # need `decimal ~> 3.0`. progress_bar only uses decimal for CLI download
      # progress formatting, so forcing 3.x is safe. Override resolves the clash.
      # Unconditional even though the clash is Bumblebee's: Ash/ecto want 3.x
      # regardless, so pinning it here keeps the resolved version the same
      # whether or not the ML stack is in the tree.
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
      # Timezone database for event recurrence and ICS (#480). Elixir ships no
      # zone data, so `DateTime.shift_zone/2` errors with `:utc_only_time_zone_database`
      # until one is configured — and recurrence is *wall-clock* by definition:
      # "every Tuesday at 19:00" must stay 19:00 across a DST boundary, which is
      # arithmetic no amount of UTC storage can do.
      #
      # `tz` rather than `tzdata`: tzdata ships a runtime updater that fetches
      # IANA releases over HTTP from a supervised process. In a codebase where
      # every other outbound call is behind an explicit flag and an SSRF-safe
      # path, a dependency that dials out on its own by default is the wrong
      # shape. `tz` compiles the data in; updating it is a dependency bump,
      # which is a decision an operator makes rather than one a background
      # process makes for them.
      {:tz, "~> 0.28"},
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
    ] ++ ml_deps()
  end

  # The optional ML stack, in the tree only when `KILN_ML` is on (#1321).
  #
  # Semantic search is disabled by default (`config :kiln_cms, KilnCMS.Search,
  # semantic: false`), and these three are 87% of the dependency tree on disk:
  # 773 MB with them, 102 MB without, `deps/exla` alone accounting for 666 MB.
  # A machine that has never built them also downloads a 110 MB prebuilt XLA
  # archive. `only: [:dev, :test]` did NOT avoid any of that: `mix deps.get`
  # fetches every dependency regardless of `:only`, which filters compilation,
  # not the download. The only way to skip the cost is to leave them out of the
  # list.
  #
  # The saving is disk and bandwidth, not wall clock: adding the stack to an
  # otherwise-complete build measured ~46 s on an Apple Silicon laptop. The
  # "~13 min compile, multi-GB RAM" this comment used to carry was stale — see
  # config/ml_flag.exs.
  #
  # Leaving them out is safe for the rest of the build because every module on
  # the semantic path degrades rather than failing to compile — see
  # `KilnCMS.Search.ML`, which is the single compile-time answer to "is this
  # build's ML stack present?" and is what `KilnCMS.Search.Serving`,
  # `KilnCMS.Search.RerankerServing`, both Bumblebee adapters and
  # `KilnCMS.Application`'s serving children branch on.
  #
  # Two things stay true whichever way the flag is set:
  #
  #   * `mix.lock` keeps its entries for all three and their transitives.
  #     `mix deps.get` does not prune the lock of deps that are not in the
  #     current tree (measured), so a lean `deps.get` cannot strip them — and
  #     `mix deps.audit`, which reads the lock alone, still audits EXLA.
  #   * `mix deps.unlock --unused` WOULD strip them, so it runs only on the ML
  #     build. See `aliases/0` and CI's `ml` job.
  #
  # EXLA keeps `only: [:dev, :test]` inside the opt-in: even with `KILN_ML=1`
  # it has no business in a prod release image, whose build host cannot afford
  # the NIF compile. Prod/e2e fall back to Nx.BinaryBackend (see
  # config/config.exs); restore EXLA there via an off-box image build before
  # enabling semantic search in production.
  defp ml_deps do
    if ml?() do
      [
        {:bumblebee, "~> 0.7"},
        {:nx, "~> 0.12"},
        {:exla, "~> 0.12", only: [:dev, :test]}
      ]
    else
      []
    end
  end

  defp ml?, do: KilnCMS.Config.MLFlag.enabled?()

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      # `kiln.ml.note` last: one line saying whether this build has the optional
      # ML stack and how to change that (#1321). It reads what actually
      # compiled (`KilnCMS.Search.ML.available?/0`) rather than the env var, so
      # it cannot disagree with the build it is describing.
      #
      # A trailing task after `run priv/repo/seeds.exs` does run — measured, and
      # not in tension with the `e2e.setup` note below: what that one records is
      # that the VM is torn down when the *chain* ends, which a `phx.server`
      # needs to outlive. A task that prints a line and returns does not.
      setup: [
        "deps.get",
        "ash.setup",
        "assets.setup",
        "assets.build",
        "run priv/repo/seeds.exs",
        "kiln.ml.note"
      ],
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
      precommit:
        ["compile --warnings-as-errors"] ++
          unlock_unused_step() ++
          [
            "format --check-formatted",
            "credo --strict",
            "sobelow --config",
            "deps.audit",
            "kiln.plugins.doctor",
            # Cheap, and says in a second what CI's `image` job takes a full
            # dependency compile to discover: a Dockerfile pin that can't satisfy
            # this file's `elixir:` requirement (#600).
            "kiln.toolchain.check",
            # An `authorize?: false` on a request path with no comment saying why
            # it is safe (#1309). Cheap, and the reason belongs next to the bypass.
            "kiln.authz.check",
            # Catches untranslated/fuzzy msgstrs locally. Read-only, so `precommit`
            # keeps its non-destructive contract — the *drift* half of the gate
            # still lives in CI only, because `gettext.extract --merge` rewrites
            # priv/gettext. Run that yourself before pushing.
            "kiln.gettext.check",
            "test"
          ]
    ]
  end

  # `deps.unlock --unused` DELETES every lock entry for a dep that is not in the
  # current tree — and without `KILN_ML` on, Bumblebee/Nx/EXLA and their eleven
  # transitives are not in the tree (#1321). Running it on a lean build would
  # silently strip them from `mix.lock`, which is both a large unrelated diff
  # and a loss of the versions `mix deps.audit` reads. So the lean build skips
  # it, and the ML build runs it — CI's `ml` job is the gate that runs the
  # read-only `--check-unused` half on the full tree.
  #
  # Fourteen lock entries hang on this: bumblebee, nx and exla, plus axon,
  # complex, nx_image, nx_signal, polaris, progress_bar, safetensors,
  # tokenizers, unpickler, unzip and xla.
  defp unlock_unused_step do
    if ml?(), do: ["deps.unlock --unused"], else: []
  end
end
