if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Kiln.Gen.Plugin do
    @example "mix kiln.gen.plugin Ratings --block star_rating"

    @moduledoc """
    Scaffold a KilnCMS **plugin** (decision D18, `docs/plugin-system-plan.md`).

    Creates `projects/<name>/plugin.ex` — a `Kiln.Plugin` module with every
    contribution callback stubbed as a commented example — registers it in
    `config :kiln_cms, :plugins`, and (with `--block`) generates a working
    sample block that immediately joins the storage union, the editor
    palette, firing and search.

    ## Example

    ```bash
    #{@example}
    ```

    ## Options

    * `--block <name>` — also generate `projects/<name>/blocks/<block>.ex`,
      a `Kiln.Block` skeleton wired into the plugin's `blocks/0`.

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
        schema: [block: :string]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      name = igniter.args.positional.name
      camel = Macro.camelize(name)
      snake = Macro.underscore(name)
      block = igniter.args.options[:block]
      plugin_module = Module.concat([camel, Plugin])

      igniter
      |> Igniter.create_new_file(
        "projects/#{snake}/plugin.ex",
        plugin_source(camel, block)
      )
      |> maybe_create_block(snake, camel, block)
      |> Igniter.Project.Config.configure(
        "config.exs",
        :kiln_cms,
        [:plugins],
        [plugin_module],
        updater: fn zipper ->
          Igniter.Code.List.append_new_to_list(zipper, plugin_module)
        end
      )
      |> Igniter.add_notice(notice(camel, snake, block))
    end

    defp maybe_create_block(igniter, _snake, _camel, nil), do: igniter

    defp maybe_create_block(igniter, snake, camel, block) do
      Igniter.create_new_file(
        igniter,
        "projects/#{snake}/blocks/#{Macro.underscore(block)}.ex",
        block_source(camel, block)
      )
    end

    # The generated plugin module. Public for unit testing.
    @doc false
    def plugin_source(camel, block) do
      blocks_line =
        if block,
          do: "def blocks, do: [#{camel}.Blocks.#{Macro.camelize(block)}]",
          else: "# def blocks, do: [#{camel}.Blocks.MyBlock]"

      """
      defmodule #{camel}.Plugin do
        @moduledoc \"\"\"
        The #{camel} plugin (see `Kiln.Plugin` and docs/plugin-system-plan.md).
        Registered via `config :kiln_cms, :plugins`; override only the
        callbacks you contribute.
        \"\"\"
        use Kiln.Plugin

        # Ash domains this plugin ships. Also register them in the host's
        # :ash_domains and :content_domains config (mix kiln.plugins.doctor
        # verifies) — content types, admin CRUD, webhooks and Oban workers
        # then flow automatically.
        # def domains, do: [#{camel}.Catalog]

        #{blocks_line}

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

    defp notice(camel, snake, block) do
      """
      Generated the #{camel} plugin at projects/#{snake}/ and registered it in
      config :kiln_cms, :plugins.
      #{if block, do: "\nIts #{block} block is live: it appears in the editor's block palette,\nstores through the block union, and renders in firing/search.\n", else: ""}
      Next:
        * Content types: mix kiln.gen.content <Type> --domain #{camel}.Catalog,
          then add #{camel}.Catalog to :ash_domains and :content_domains.
        * Verify the install: mix kiln.plugins.doctor (also runs in precommit).
      """
    end
  end
end
