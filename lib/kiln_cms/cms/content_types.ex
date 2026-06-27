defmodule KilnCMS.CMS.ContentTypes do
  @moduledoc """
  Registry of content types for the admin UI.

  Content types are **discovered automatically**: any resource built on
  `KilnCMS.CMS.Content` is picked up here, so a type generated with
  `mix kiln.gen.content` shows up in the editor with no extra wiring.

  Discovery spans every domain listed in the `:content_domains` config (default
  `[KilnCMS.CMS]`). This lets the reusable core stay project-agnostic while a
  project registers its own content types on its own domain, e.g.:

      config :kiln_cms, :content_domains, [KilnCMS.CMS, Verscienta.Catalog]

  It also centralizes dispatch to the per-type code interfaces (whose names
  follow the project's convention) **on each type's own domain**, so the
  LiveViews can stay generic instead of hard-coding `:page`/`:post`.
  """
  alias KilnCMS.CMS

  @type t :: %{
          type: atom(),
          resource: module(),
          domain: module(),
          label: String.t(),
          plural: String.t(),
          excerpt?: boolean(),
          path_segment: String.t() | nil
        }

  @doc "The Ash domains scanned for content types (default `[KilnCMS.CMS]`)."
  @spec content_domains() :: [module()]
  def content_domains, do: Application.get_env(:kiln_cms, :content_domains, [CMS])

  @doc "All content types, sorted by label."
  @spec all() :: [t()]
  def all do
    content_domains()
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&function_exported?(&1, :__kiln_content_type__, 0))
    |> Enum.map(&describe/1)
    |> Enum.sort_by(& &1.label)
  end

  defp describe(resource) do
    type = resource.__kiln_content_type__()
    plural = resource.__kiln_content_plural__()

    %{
      type: type,
      resource: resource,
      domain: Ash.Resource.Info.domain(resource),
      label: resource |> Module.split() |> List.last(),
      plural: plural,
      excerpt?: not is_nil(Ash.Resource.Info.attribute(resource, :excerpt)),
      path_segment: path_segment(type, plural)
    }
  end

  # The first URL segment for public delivery. Pages live at the root
  # (`/<slug>`), posts keep their historical `/blog/<slug>`, and every other
  # type is served at `/<plural>/<slug>`.
  defp path_segment(:page, _plural), do: nil
  defp path_segment(:post, _plural), do: "blog"
  defp path_segment(_type, plural), do: plural

  @doc "Public URL prefix for a content type (`\"\"` for pages served at root)."
  @spec public_prefix(t()) :: String.t()
  def public_prefix(%{path_segment: nil}), do: ""
  def public_prefix(%{path_segment: segment}), do: "/" <> segment

  @doc ~S(Find a content type by its public URL segment, e.g. "blog" or "products".)
  @spec get_by_path(String.t()) :: t() | nil
  def get_by_path(segment), do: Enum.find(all(), &(&1.path_segment == segment))

  @doc "The atom types of all content types."
  @spec types() :: [atom()]
  def types, do: Enum.map(all(), & &1.type)

  @doc "Look up a content type by its atom or string type. Returns nil if unknown."
  @spec get(atom() | String.t() | nil) :: t() | nil
  def get(nil), do: nil
  def get(type) when is_atom(type), do: Enum.find(all(), &(&1.type == type))

  def get(type) when is_binary(type) do
    case safe_existing_atom(type) do
      nil -> nil
      atom -> get(atom)
    end
  end

  @doc "Like `get/1` but raises for an unknown type."
  @spec get!(atom() | String.t()) :: t()
  def get!(type) do
    get(type) || raise ArgumentError, "unknown content type: #{inspect(type)}"
  end

  @doc "Whether `type` is a known content type."
  @spec type?(atom() | String.t()) :: boolean()
  def type?(type), do: not is_nil(get(type))

  # --- dispatch to the per-type code interfaces ------------------------------
  #
  # Each helper accepts a type atom or string and calls the
  # convention-named code interface on that type's own domain, e.g.
  # `KilnCMS.CMS.list_pages!/1` or `Verscienta.Catalog.list_herbs!/1`.

  def list!(type, opts \\ []), do: call(type, "list_#{plural(type)}!", [opts])

  def get_record!(type, id, opts \\ []), do: call(type, "get_#{atom(type)}!", [id, opts])

  # Non-bang fetch by id (`{:ok, record} | {:error, _}`), e.g. for preview links.
  def get_record(type, id, opts \\ []), do: call(type, "get_#{atom(type)}", [id, opts])

  # Public delivery: fetch a single published record by slug + locale (returns
  # nil rather than raising on a miss).
  def get_published_by_slug(type, slug, locale, opts \\ []) do
    call(type, "get_published_#{atom(type)}_by_slug!", [slug, locale, opts])
  end

  # Every published locale variant of a slug (for hreflang / language switching).
  def list_translations(type, slug, opts \\ []) do
    call(type, "list_#{atom(type)}_translations!", [slug, opts])
  end

  def create!(type, attrs, opts \\ []), do: call(type, "create_#{atom(type)}!", [attrs, opts])

  def list_versions!(type, opts \\ []), do: call(type, "list_#{atom(type)}_versions!", [opts])

  def restore_version(type, record, version_id, opts \\ []) do
    call(type, "restore_#{atom(type)}_version", [record, %{version_id: version_id}, opts])
  end

  @doc "Run a workflow transition: publish, unpublish, submit, or archive."
  def transition(type, verb, record, opts \\ []) do
    call(type, transition_fun(atom(type), verb), [record, %{}, opts])
  end

  def list_trashed!(type, opts \\ []), do: call(type, "list_trashed_#{plural(type)}!", [opts])

  def restore(type, record, opts \\ []),
    do: call(type, "restore_#{atom(type)}", [record, %{}, opts])

  def purge(type, record, opts \\ []), do: call(type, "purge_#{atom(type)}", [record, opts])

  def destroy(type, record, opts \\ []), do: call(type, "destroy_#{atom(type)}", [record, opts])

  # --- internals -------------------------------------------------------------

  # Resolve a convention-built interface name to the existing function on the
  # type's domain and call it. `to_existing_atom` (not interpolation) keeps this
  # safe for request-derived types — the code interfaces are defined at compile
  # time.
  defp call(type, fun_name, args) do
    apply(domain_for(type), String.to_existing_atom(fun_name), args)
  end

  defp domain_for(type), do: get!(type).domain

  defp transition_fun(type, "publish"), do: "publish_#{type}"
  defp transition_fun(type, "unpublish"), do: "unpublish_#{type}"
  defp transition_fun(type, "submit"), do: "submit_#{type}_for_review"
  defp transition_fun(type, "return"), do: "return_#{type}_to_draft"
  defp transition_fun(type, "archive"), do: "archive_#{type}"

  defp atom(type) when is_atom(type), do: type
  defp atom(type) when is_binary(type), do: get!(type).type

  defp plural(type), do: get!(type).plural

  defp safe_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end
end
