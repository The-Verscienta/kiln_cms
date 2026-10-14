if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Kiln.Gen.Plugin do
    @example "mix kiln.gen.plugin Ratings --block star_rating --field stars"

    @moduledoc """
    Scaffold a KilnCMS **plugin** (decision D18, `docs/plugin-system-plan.md`).

    Creates `projects/<name>/plugin.ex` — a `Kiln.Plugin` module with every
    contribution callback stubbed as a commented example — registers it in
    `config :kiln_cms, :plugins`, and (with `--block` / `--field`) generates
    working sample contributions that immediately join the system.

    ## Example

    ```bash
    #{@example}
    ```

    ## Options

    * `--block <name>` — also generate `projects/<name>/blocks/<block>.ex`,
      a `Kiln.Block` skeleton wired into the plugin's `blocks/0`.
    * `--field <name>` — also generate
      `projects/<name>/field_types/<field>.ex`, a `Kiln.FieldType` skeleton
      wired into the plugin's `field_types/0` — admins can then pick the
      type in the fields admin (`/editor/fields`).
    * `--dep` — generate a plugin that ships as a Mix dependency instead of a
      `projects/` overlay (#1909): a standalone Mix project depending only on
      `kiln_plugin`, written to `../<name>` (beside the core checkout, since
      it is its own repository) or to `--path`. `--block` and `--field` go
      under its `lib/`. Nothing in the core changes: a dependency's modules
      are not loadable until the site adds the dependency, so registering it
      in `:plugins` is a step for later, listed in the notice.
    * `--path <dir>` — with `--dep`, where to write the project.

    A dependency plugin can contribute blocks, field types, spam checks,
    advisory checks, image backends, nav items, children and queues; one that
    needs content types, Ash domains or `KilnCMSWeb` stays an overlay (see
    `Kiln.Plugin`, "As a Mix dependency, or as a `projects/` overlay").

    Content types come next: generate them with
    `mix kiln.gen.content <Type> --domain <Plugin>.Catalog` and register the
    domain in `:ash_domains`/`:content_domains` — then verify the install
    with `mix kiln.plugins.doctor` (it runs in precommit too).
    """
    @shortdoc "Generate a KilnCMS plugin skeleton"
    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        positional: [:name],
        example: @example,
        schema: [block: :string, field: :string, dep: :boolean, path: :string]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      name = igniter.args.positional.name
      camel = Macro.camelize(name)
      snake = Macro.underscore(name)
      block = igniter.args.options[:block]
      field = igniter.args.options[:field]
      plugin_module = Module.concat([camel, Plugin])

      cond do
        igniter.args.options[:dep] ->
          dep_igniter(igniter, camel, snake, block, field)

        igniter.args.options[:path] ->
          Igniter.add_issue(
            igniter,
            "--path only applies with --dep: an overlay goes in projects/."
          )

        true ->
          overlay_igniter(igniter, camel, snake, block, field, plugin_module)
      end
    end

    defp overlay_igniter(igniter, camel, snake, block, field, plugin_module) do
      igniter
      |> Igniter.create_new_file(
        "projects/#{snake}/plugin.ex",
        plugin_source(camel, block, field)
      )
      |> maybe_create_block(snake, camel, block)
      |> maybe_create_field(snake, camel, field)
      |> Igniter.Project.Config.configure(
        "config.exs",
        :kiln_cms,
        [:plugins],
        [plugin_module],
        updater: fn zipper ->
          Igniter.Code.List.append_new_to_list(zipper, plugin_module)
        end
      )
      |> Igniter.add_notice(notice(camel, snake, block, field))
    end

    # A standalone Mix project. Every file goes under `root`; nothing in the
    # core is touched (see the moduledoc).
    defp dep_igniter(igniter, camel, snake, block, field) do
      root = igniter.args.options[:path] || Path.join("..", snake)

      [
        {"mix.exs", dep_mix_source(camel, snake, block)},
        {".formatter.exs", dep_formatter_source()},
        {".gitignore", "/_build/\n/deps/\n/doc/\nerl_crash.dump\n"},
        {"config/config.exs", dep_config_source()},
        {"README.md", dep_readme_source(camel, snake)},
        {"lib/#{snake}/plugin.ex", plugin_source(camel, block, field, dep: true)},
        {"test/test_helper.exs", "ExUnit.start()\n"},
        {"test/#{snake}_test.exs", dep_test_source(camel)}
      ]
      |> maybe_add(block, fn block ->
        {"lib/#{snake}/blocks/#{Macro.underscore(block)}.ex", block_source(camel, block)}
      end)
      |> maybe_add(field, fn field ->
        {"lib/#{snake}/field_types/#{Macro.underscore(field)}.ex", field_source(camel, field)}
      end)
      |> Enum.reduce(igniter, fn {path, source}, igniter ->
        Igniter.create_new_file(igniter, Path.join(root, path), source)
      end)
      |> Igniter.add_notice(dep_notice(camel, snake, root))
    end

    defp maybe_add(files, nil, _build), do: files
    defp maybe_add(files, name, build), do: files ++ [build.(name)]

    defp maybe_create_block(igniter, _snake, _camel, nil), do: igniter

    defp maybe_create_block(igniter, snake, camel, block) do
      Igniter.create_new_file(
        igniter,
        "projects/#{snake}/blocks/#{Macro.underscore(block)}.ex",
        block_source(camel, block)
      )
    end

    defp maybe_create_field(igniter, _snake, _camel, nil), do: igniter

    defp maybe_create_field(igniter, snake, camel, field) do
      Igniter.create_new_file(
        igniter,
        "projects/#{snake}/field_types/#{Macro.underscore(field)}.ex",
        field_source(camel, field)
      )
    end

    # The generated plugin module. Public for unit testing.
    @doc false
    def plugin_source(camel, block, field \\ nil, opts \\ []) do
      blocks_line =
        if block,
          do: "def blocks, do: [#{camel}.Blocks.#{Macro.camelize(block)}]",
          else: "# def blocks, do: [#{camel}.Blocks.MyBlock]"

      field_types_line =
        if field,
          do: "def field_types, do: [#{camel}.FieldTypes.#{Macro.camelize(field)}]",
          else: "# def field_types, do: [#{camel}.FieldTypes.MyFieldType]"

      # A dependency compiles before the core, so it cannot ship Ash domains
      # (they need the core's repo and policies); the overlay comment says so.
      domains_lines =
        if opts[:dep],
          do: """
            # Content types and Ash domains need the core, so a plugin that ships
            # them is a projects/ overlay (mix kiln.gen.plugin without --dep).
          """,
          else: """
            # Ash domains this plugin ships. Also register them in the host's
            # :ash_domains and :content_domains config (mix kiln.plugins.doctor
            # verifies) — content types, admin CRUD, webhooks and Oban workers
            # then flow automatically.
            # def domains, do: [#{camel}.Catalog]
          """

      """
      defmodule #{camel}.Plugin do
        @moduledoc \"\"\"
        The #{camel} plugin (see `Kiln.Plugin` and docs/plugin-system-plan.md).
        Registered via `config :kiln_cms, :plugins`; override only the
        callbacks you contribute.
        \"\"\"
        use Kiln.Plugin

        # One line saying what this plugin does for a site — shown in the
        # console's System → Plugins panel and by `mix kiln.plugins.list`.
        @impl true
        def summary, do: "TODO: say what #{camel} adds to a Kiln site."

        # def version, do: "0.1.0"
        # def homepage, do: "https://github.com/<you>/#{Macro.underscore(camel)}"

      #{domains_lines}
        #{blocks_line}

        #{field_types_line}

        # def advisories, do: [#{camel}.Advisories.MyCheck]

        # def nav_items, do: [%{label: "#{camel}", path: "/editor/#{Macro.underscore(camel)}", role: :admin}]
        # def admin_routes, do: [{"/editor/#{Macro.underscore(camel)}", #{camel}.PanelLive, :index}]
        # def children, do: [#{camel}.Worker]
        # def oban_queues, do: [#{Macro.underscore(camel)}: 2]
      end
      """
    end

    # The generated sample block. Public for unit testing.
    @doc false
    def block_source(camel, block) do
      block_snake = Macro.underscore(block)
      block_camel = Macro.camelize(block)

      """
      defmodule #{camel}.Blocks.#{block_camel} do
        @moduledoc "A #{camel} block type — joins the editor palette, storage, firing and search."
        use Kiln.Block

        block :#{block_snake} do
          field :text, :string, required: true
        end

        # Match plain variables here — never `%__MODULE__{}` (the struct is
        # built at @before_compile; matching it breaks clean compiles).
        @impl Kiln.Block.Renderer
        def render(block, :web), do: ["<div class=\\"#{block_snake}\\">", esc(block.text || ""), "</div>"]
        def render(_block, _surface), do: nil

        @impl Kiln.Block.Renderer
        def search_text(block), do: block.text || ""

        defp esc(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
      end
      """
    end

    # The generated sample field type. Public for unit testing.
    @doc false
    def field_source(camel, field) do
      field_camel = Macro.camelize(field)

      """
      defmodule #{camel}.FieldTypes.#{field_camel} do
        @moduledoc \"\"\"
        A #{camel} custom field type — admins pick it in the fields admin
        (/editor/fields); `cast/2` gates every content write (see
        `Kiln.FieldType`). Return JSON-native values only: they live in the
        `custom_fields` jsonb column and are served on delivery as-is.
        \"\"\"
        use Kiln.FieldType

        @impl Kiln.FieldType
        def cast(value, _definition) do
          # Coerce + validate the submitted value (never called blank —
          # `required`/`default` handling is the host's job).
          {:ok, value |> to_string() |> String.trim()}
        end

        # Shown under the type picker once an admin selects it: what the field
        # holds and what it is for.
        # def description, do: "One to five stars. For a review score."

        # The editor renders <input type={input_type()} {input_attrs(definition)}>.
        # def input_type, do: "number"
        # def input_attrs(_definition), do: %{min: 1, max: 5}

        # Browser behaviour (a type-ahead, a picker): name a colocated hook
        # declared in this module (`use Phoenix.Component` for that), and
        # answer its "kiln:field_event" pushes. See Kiln.FieldType, "Client hooks".
        # def input_hook(_definition),
        #   do: %{hook: Kiln.FieldType.colocated_hook(__MODULE__, "Picker"), data: %{}}
        # def handle_input_event("lookup", %{"q" => q}, _context), do: {:ok, %{results: []}}
      end
      """
    end

    # `--dep`: the project's mix.exs. Public for unit testing.
    @doc false
    def dep_mix_source(camel, snake, block) do
      # The sample block escapes with Phoenix.HTML; a dependency sees only its
      # own deps, so it has to ask for it (the core's lock decides the version).
      phoenix_html = if block, do: ",\n        {:phoenix_html, \"~> 4.1\"}", else: ""

      """
      defmodule #{camel}.MixProject do
        use Mix.Project

        def project do
          [
            app: :#{snake},
            version: "0.1.0",
            elixir: "~> 1.20",
            start_permanent: Mix.env() == :prod,
            deps: deps()
          ]
        end

        def application do
          [extra_applications: [:logger]]
        end

        # kiln_plugin is the whole plugin contract (#1909). Inside a KilnCMS
        # build the core bundles it, and `mix kiln.plugins.doctor` checks this
        # requirement accepts that version.
        defp deps do
          [
            {:kiln_plugin, "#{sdk_requirement()}"}#{phoenix_html}
          ]
        end
      end
      """
    end

    @doc false
    # The bundled SDK's minor, so a generated plugin can use everything this
    # core offers and still accepts every later 1.x (`~> 1.1` for 1.1.0).
    def sdk_requirement do
      _ = Application.load(:kiln_plugin)
      version = :kiln_plugin |> Application.spec(:vsn) |> to_string() |> Version.parse!()
      "~> #{version.major}.#{version.minor}"
    end

    defp dep_formatter_source do
      """
      # import_deps brings in the block DSL's no-parentheses calls.
      [
        import_deps: [:kiln_plugin],
        inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
      ]
      """
    end

    # Used only when the plugin compiles on its own (its own CI, `mix test`);
    # inside a site the core's config applies.
    defp dep_config_source do
      """
      import Config

      # Every block is an embedded Ash resource, and Ash refuses to compile a
      # `:string` attribute until this is chosen. The KilnCMS core sets the same.
      config :ash, default_string_length_count: :codepoints
      """
    end

    defp dep_test_source(camel) do
      """
      defmodule #{camel}Test do
        use ExUnit.Case, async: true

        test "the plugin describes itself" do
          assert is_binary(#{camel}.Plugin.summary())
        end
      end
      """
    end

    defp dep_readme_source(camel, snake) do
      """
      # #{camel}

      A [KilnCMS](https://github.com/The-Verscienta/kiln_cms) plugin, shipped
      as a Mix dependency. It depends only on
      [`kiln_plugin`](https://github.com/The-Verscienta/kiln_cms/blob/main/sdk/kiln_plugin/README.md),
      the plugin contract.

      ## Installing

      1. Add the dependency to the site's overlay, in `config/project_deps.exs`:

         ```elixir
         [{:#{snake}, git: "https://github.com/<you>/#{snake}", tag: "v0.1.0"}]
         ```

      2. Register the plugin, in `config/project.exs`:

         ```elixir
         config :kiln_cms, :plugins, [#{camel}.Plugin]
         ```

      3. Check the install: `mix kiln.plugins.doctor`.
      """
    end

    defp dep_notice(camel, snake, root) do
      """
      Generated the #{camel} plugin as a standalone Mix project at #{root}/.
      It depends only on kiln_plugin; nothing in this checkout changed.

      Next:
        * Build it on its own: cd #{root} && mix deps.get && mix test
        * Install it in a site: add {:#{snake}, ...} (Hex, git: or path:) to the
          overlay's config/project_deps.exs, then
          config :kiln_cms, :plugins, [#{camel}.Plugin] (see #{root}/README.md).
        * Verify the install: mix kiln.plugins.doctor.
      """
    end

    defp notice(camel, snake, block, field) do
      """
      Generated the #{camel} plugin at projects/#{snake}/ and registered it in
      config :kiln_cms, :plugins.
      #{if block, do: "\nIts #{block} block is live: it appears in the editor's block palette,\nstores through the block union, and renders in firing/search.\n", else: ""}#{if field, do: "\nIts #{field} field type is live: admins can pick it at /editor/fields,\nand its cast/2 gates content writes.\n", else: ""}
      Next:
        * Content types: mix kiln.gen.content <Type> --domain #{camel}.Catalog,
          then add #{camel}.Catalog to :ash_domains and :content_domains.
        * Verify the install: mix kiln.plugins.doctor (also runs in precommit).
      """
    end
  end
end
