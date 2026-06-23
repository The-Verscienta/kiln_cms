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

    ## Options

    * `--excerpt` / `-e` - add an `excerpt` field (for listings/feeds).
    * `--published` / `-p` - add a `:published` read + `list_published_*` interface.
    * `--plural` - override the plural used in interface names (default `<type>s`).

    After running, generate and apply the migration:

    ```bash
    mix ash.codegen add_<plural> && mix ash.migrate
    ```
    """
    @shortdoc "Generate a KilnCMS content type"
    use Igniter.Mix.Task

    @domain KilnCMS.CMS

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        positional: [:name],
        example: @example,
        schema: [excerpt: :boolean, published: :boolean, plural: :string],
        aliases: [e: :excerpt, p: :published]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options
      module = resource_module(igniter.args.positional.name)
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
      |> Igniter.add_notice(notice(module, plural))
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
        {:"publish_#{type}", "define :publish_#{type}, action: :publish"},
        {:"publish_scheduled_#{type}",
         "define :publish_scheduled_#{type}, action: :publish_scheduled"},
        {:"unpublish_#{type}", "define :unpublish_#{type}, action: :unpublish"},
        {:"archive_#{type}", "define :archive_#{type}, action: :archive"},
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

    defp notice(module, plural) do
      """
      Added content type #{inspect(module)} and its CMS.* code interfaces.

      Next:
        1. Generate and apply the migration:
             mix ash.codegen add_#{plural} && mix ash.migrate

      It is already taggable and linkable to any other content type (via the
      shared Tagging / ContentLink tables) — no join tables needed.

      Optional follow-ups (reverse navigation + taxonomy counts), if you want
      them, add by hand:
        * KilnCMS.CMS.Category — `has_many :#{plural}, #{inspect(module)}`
        * KilnCMS.CMS.Tag — a `many_to_many :#{plural}` through `KilnCMS.CMS.Tagging`
          (source `:tag_id`, destination `:subject_id`) + a `count :#{String.trim_trailing(plural, "s")}_count` aggregate
        * KilnCMS.CMS.MediaItem — `has_many :featured_#{plural}, #{inspect(module)}`
          (destination_attribute `:featured_image_id`)
        * Wire the type into KilnCMSWeb.ContentEditorLive to edit it in the admin UI.
      """
    end
  end
end
