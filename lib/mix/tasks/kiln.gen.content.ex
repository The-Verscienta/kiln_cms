if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Kiln.Gen.Content do
    @example "mix kiln.gen.content Product --excerpt --published"

    @moduledoc """
    Scaffold a new KilnCMS content type.

    Creates a resource built on `KilnCMS.CMS.Content` (so it inherits the block
    editor model, publishing workflow, version history, search, SEO, and the
    standard relationships) and registers it on the `KilnCMS.CMS` domain with the
    full set of `CMS.*` code interfaces. Thanks to the polymorphic `Tagging` /
    `ContentLink` layer, the new type is immediately taggable and linkable to any
    other content type — no join tables to author.

    ## Example

    ```bash
    #{@example}
    ```

    ## Arguments

    * `name` - the content type, e.g. `Product` or a fully-qualified module
      (`KilnCMS.CMS.Product`). Bare names are placed under `KilnCMS.CMS`.
      Optional with `--from` (defaults to the dynamic type's name, camelized).

    ## Options

    * `--excerpt` / `-e` - add an `excerpt` field (for listings/feeds).
    * `--published` / `-p` - add a `:published` read + `list_published_*` interface.
    * `--plural` - override the plural used in interface names (default `<type>s`).
    * `--from <name>` - **promote an admin-defined dynamic type** (decision
      D17): derives the module, flags and plural from its `TypeDefinition`.
      After the migration, run `mix kiln.promote_data <name>` to move its
      entries, versions and custom-field definitions over. Fields stay
      data-driven (the editor renders from `FieldDefinition` rows); promote
      individual fields to real attributes by hand when querying demands it.

    After running, generate and apply the migration:

    ```bash
    mix ash.codegen add_<plural> && mix ash.migrate
    ```

    …then add a `search_vector` migration for the new table (the printed notice
    includes a copy-paste template) — `KilnCMS.Migrations.add_search_vector/1`
    explains why codegen can't do this one.
    """
    @shortdoc "Generate a KilnCMS content type"
    use Igniter.Mix.Task

    @domain KilnCMS.CMS

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        positional: [name: [optional: true]],
        example: @example,
        schema: [excerpt: :boolean, published: :boolean, plural: :string, from: :string],
        aliases: [e: :excerpt, p: :published]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = derive_opts(igniter.args.options)
      name = igniter.args.positional[:name] || default_name!(opts)
      module = resource_module(name)
      type = type_atom(module)
      plural = opts[:plural] || "#{type}s"
      version = Module.concat(module, Version)

      igniter
      |> Igniter.Project.Module.create_module(module, resource_body(module, type, opts))
      |> Ash.Domain.Igniter.add_resource_reference(@domain, module)
      |> Ash.Domain.Igniter.add_resource_reference(@domain, version)
      |> add_interfaces(module, interfaces(type, plural, opts))
      |> add_interfaces(version, [
        {:"list_#{type}_versions", "define :list_#{type}_versions, action: :read"}
      ])
      |> Igniter.add_notice(notice(module, type, plural))
      |> maybe_add_promotion_notice(opts)
    end

    # With --from, flags/plural come from the dynamic type's TypeDefinition
    # (explicit CLI flags still win).
    defp derive_opts(opts) do
      case opts[:from] do
        nil ->
          opts

        name ->
          Mix.Task.run("app.start")
          definition = KilnCMS.CMS.get_type_definition_by_name!(name, authorize?: false)
          Keyword.merge(promotion_opts(definition), opts)
      end
    end

    # The generator options a TypeDefinition maps to. Public for unit testing.
    # A path_segment that isn't a valid identifier fragment can't become the
    # interface-name plural — fall back to the default and note the URL change.
    @doc false
    def promotion_opts(definition) do
      plural =
        if definition.path_segment =~ ~r/\A[a-z][a-z0-9_]*\z/ do
          definition.path_segment
        end

      [excerpt: definition.has_excerpt, published: definition.has_published_feed] ++
        if(plural, do: [plural: plural], else: [])
    end

    defp default_name!(opts) do
      case opts[:from] do
        nil ->
          Mix.raise(
            "usage: mix kiln.gen.content <Name> [flags] | mix kiln.gen.content --from <name>"
          )

        name ->
          Macro.camelize(name)
      end
    end

    defp maybe_add_promotion_notice(igniter, opts) do
      case opts[:from] do
        nil ->
          igniter

        name ->
          plural = opts[:plural] || "#{name}s"

          Igniter.add_notice(igniter, """
          Promoting dynamic type "#{name}" (D17). After the migration above, move
          its data over:

              mix kiln.promote_data #{name}

          That relocates its entries (ids preserved), version history, and
          custom-field definitions, then archives the TypeDefinition. Its custom
          fields stay data-driven — promote individual fields to real attributes
          by hand when querying/indexing demands it.#{url_change_note(name, plural)}
          """)
      end
    end

    # Compiled types serve at /<plural>/<slug>; if the dynamic type used a
    # different segment, its public URLs move.
    defp url_change_note(name, plural) do
      definition = KilnCMS.CMS.get_type_definition_by_name!(name, authorize?: false)

      if definition.path_segment == plural do
        ""
      else
        "\n\nNOTE: public URLs move from /#{definition.path_segment}/<slug> to " <>
          "/#{plural}/<slug> (the segment isn't usable as an interface plural)."
      end
    end

    defp add_interfaces(igniter, resource, interfaces) do
      Enum.reduce(interfaces, igniter, fn {name, definition}, igniter ->
        Ash.Domain.Igniter.add_new_code_interface(igniter, @domain, resource, name, definition)
      end)
    end

    # The standard CMS.* interface set, mirroring Page/Post. Public so it can be
    # unit-tested without running the full codemod.
    @doc false
    def interfaces(type, plural, opts) do
      base = [
        {:"list_#{plural}", "define :list_#{plural}, action: :read"},
        {:"get_#{type}", "define :get_#{type}, action: :read, get_by: [:id]"},
        {:"get_published_#{type}_by_slug",
         "define :get_published_#{type}_by_slug, action: :public_by_slug, args: [:slug]"},
        {:"search_#{plural}", "define :search_#{plural}, action: :search, args: [:query]"},
        {:"create_#{type}", "define :create_#{type}, action: :create"},
        {:"update_#{type}", "define :update_#{type}, action: :update"},
        {:"submit_#{type}_for_review",
         "define :submit_#{type}_for_review, action: :submit_for_review"},
        {:"return_#{type}_to_draft", "define :return_#{type}_to_draft, action: :return_to_draft"},
        {:"publish_#{type}", "define :publish_#{type}, action: :publish"},
        {:"publish_scheduled_#{type}",
         "define :publish_scheduled_#{type}, action: :publish_scheduled"},
        {:"unpublish_#{type}", "define :unpublish_#{type}, action: :unpublish"},
        {:"archive_#{type}", "define :archive_#{type}, action: :archive"},
        {:"unarchive_#{type}", "define :unarchive_#{type}, action: :unarchive"},
        {:"restore_#{type}_version", "define :restore_#{type}_version, action: :restore_version"},
        {:"destroy_#{type}", "define :destroy_#{type}, action: :destroy"},
        {:"list_trashed_#{plural}", "define :list_trashed_#{plural}, action: :trashed"},
        {:"restore_#{type}", "define :restore_#{type}, action: :restore"},
        {:"purge_#{type}", "define :purge_#{type}, action: :purge"}
      ]

      if opts[:published] do
        base ++
          [{:"list_published_#{plural}", "define :list_published_#{plural}, action: :published"}]
      else
        base
      end
    end

    # The body injected into the new resource module. Public for unit testing.
    @doc false
    def resource_body(module, type, opts) do
      flags =
        [{:excerpt?, opts[:excerpt]}, {:published?, opts[:published]}]
        |> Enum.filter(&elem(&1, 1))
        |> Enum.map_join("", fn {k, _} -> ", #{k}: true" end)

      label = module |> Module.split() |> List.last()

      """
      @moduledoc \"\"\"
      A #{label} — a KilnCMS content type. All of its behaviour (block editor,
      publishing workflow, version history, search, SEO, and the standard
      relationships) comes from `KilnCMS.CMS.Content`; add only what is unique to
      a #{label} below.
      \"\"\"
      use KilnCMS.CMS.Content, type: #{inspect(type)}#{flags}
      """
    end

    defp resource_module(name) do
      parsed = Igniter.Project.Module.parse(name)

      if name =~ "." do
        parsed
      else
        Module.concat(@domain, parsed)
      end
    end

    defp type_atom(module) do
      module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
    end

    defp notice(module, type, plural) do
      # The macro's table default, NOT the route/interface plural — a
      # `--plural` override changes routes, not the table.
      table = "#{type}s"

      """
      Added content type #{inspect(module)} and its CMS.* code interfaces.

      Next:
        1. Generate and apply the migration:
             mix ash.codegen add_#{plural} && mix ash.migrate
        2. Wire up full-text search — the `/#{plural}/search` route 500s without
           it. `search_vector` is trigger-maintained in the database, not an Ash
           attribute, so ash.codegen can't create it (and this generator can't
           either: the migration must sort AFTER step 1's). Add one that calls
           the helper:

             defmodule KilnCMS.Repo.Migrations.Add#{Macro.camelize(table)}SearchVector do
               use Ecto.Migration

               import KilnCMS.Migrations

               def up, do: add_search_vector("#{table}")
               def down, do: drop_search_vector("#{table}")
             end

      Then it just works, no further wiring:
        * Editable in the admin (auto-discovered — appears as "New #{plural}").
        * Served publicly at /#{plural}/<slug> (and listed in sitemap.xml).
        * Taggable and linkable to any other content type (shared Tagging /
          ContentLink tables) — no join tables needed.

      Optional follow-ups (reverse navigation + taxonomy counts), if you want
      them, add by hand:
        * KilnCMS.CMS.Category — `has_many :#{plural}, #{inspect(module)}`
        * KilnCMS.CMS.Tag — a `many_to_many :#{plural}` through `KilnCMS.CMS.Tagging`
          (source `:tag_id`, destination `:subject_id`) + a `count :#{String.trim_trailing(plural, "s")}_count` aggregate
        * KilnCMS.CMS.MediaItem — `has_many :featured_#{plural}, #{inspect(module)}`
          (destination_attribute `:featured_image_id`)
      """
    end
  end
end
