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
          type: atom() | String.t(),
          resource: module() | nil,
          domain: module(),
          label: String.t(),
          plural: String.t(),
          section: atom() | nil,
          excerpt?: boolean(),
          path_segment: String.t() | nil,
          source: :compiled | :dynamic,
          definition: struct() | nil
        }

  # First URL segments the router owns — a dynamic type's `path_segment` (its
  # public `/<segment>/<slug>` prefix) may not shadow any of these. Compiled
  # types' segments and configured locales are added at validation time (see
  # `Validations.AvailableTypeName`). Keep in sync with the top-level scopes in
  # `KilnCMSWeb.Router`.
  @reserved_path_segments ~w(admin api auth blog content dev editor gql locale
                             mailbox media playground preview register reset
                             search sign_in swaggerui up)

  @doc "The Ash domains scanned for content types (default `[KilnCMS.CMS]`)."
  @spec content_domains() :: [module()]
  def content_domains, do: Application.get_env(:kiln_cms, :content_domains, [CMS])

  @doc """
  All **compiled** content types, sorted by label.

  Compiled-only on purpose: every consumer of `all/0` (delivery, sitemap,
  webhooks, the `call/3` dispatch below) relies on a backing resource module
  and code interfaces, which dynamic types don't have until the generic entry
  tier lands (see `docs/dynamic-content-types-plan.md`, Phase 2). Use
  `dynamic_all/0` for admin-defined types.
  """
  @spec all() :: [t()]
  def all do
    content_domains()
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.filter(&function_exported?(&1, :__kiln_content_type__, 0))
    |> Enum.map(&describe/1)
    |> Enum.sort_by(& &1.label)
  end

  # TTL backstop for the cached dynamic registry; the real freshness signal is
  # `Changes.BustTypeRegistry` on every TypeDefinition write.
  @registry_ttl :timer.minutes(5)

  @doc """
  All **admin-defined (dynamic)** content types, as registry descriptors,
  sorted by label. Their `type` is the definition's name **string** — dynamic
  types never mint atoms (D17).

  Cached (`KilnCMS.Cache`): this sits on the anonymous delivery path via
  `get_by_path/1`, so it must not cost a DB round-trip per request. Busted on
  every TypeDefinition write, TTL as the backstop.
  """
  # Multi-tenancy (epic #336): the dynamic-type registry is per-org — a
  # `TypeDefinition` belongs to one site. `org_id` defaults to the sole org so
  # every tenant-less caller keeps working under the single-org rollout; the
  # delivery/editor hot paths thread the request's real org. Cached per-org (the
  # key carries `org_id`), so one site's types never leak into another's.
  @spec dynamic_all(Ash.UUID.t()) :: [t()]
  def dynamic_all(org_id \\ KilnCMS.Accounts.default_org_id()) do
    if cache_registry?() do
      KilnCMS.Cache.fetch(
        KilnCMS.Cache.type_registry_key(org_id),
        @registry_ttl,
        fn -> load_dynamic(org_id) end
      )
    else
      load_dynamic(org_id)
    end
  end

  defp load_dynamic(org_id) do
    KilnCMS.CMS.list_type_definitions!(authorize?: false, tenant: org_id)
    |> Enum.map(&describe_dynamic/1)
    |> Enum.sort_by(& &1.label)
  end

  # Off in tests: the cache is a global Cachex key while test sandboxes are
  # per-test, so a cached registry would leak one test's types into another.
  defp cache_registry? do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:cache_registry?, true)
  end

  @doc """
  Look up a dynamic content type by its name string, within `org_id` (defaults to
  the sole org — epic #336). Returns nil if unknown.
  """
  @spec get_dynamic(String.t(), Ash.UUID.t()) :: t() | nil
  def get_dynamic(name, org_id \\ KilnCMS.Accounts.default_org_id()) when is_binary(name),
    do: Enum.find(dynamic_all(org_id), &(&1.type == name))

  @doc "Router-owned first URL segments a dynamic type may not use."
  @spec reserved_path_segments() :: [String.t()]
  def reserved_path_segments, do: @reserved_path_segments

  defp describe(resource) do
    type = resource.__kiln_content_type__()
    plural = resource.__kiln_content_plural__()

    %{
      type: type,
      resource: resource,
      domain: Ash.Resource.Info.domain(resource),
      label: resource |> Module.split() |> List.last(),
      plural: plural,
      section: resource.__kiln_content_section__(),
      excerpt?: not is_nil(Ash.Resource.Info.attribute(resource, :excerpt)),
      path_segment: path_segment(type, plural),
      source: :compiled,
      definition: nil
    }
  end

  defp describe_dynamic(definition) do
    %{
      type: definition.name,
      resource: nil,
      domain: CMS,
      label: definition.label,
      plural: definition.plural_label || definition.label,
      # Dynamic types never mint atoms (D17) — they have no section key.
      section: nil,
      excerpt?: definition.has_excerpt,
      path_segment: definition.path_segment,
      source: :dynamic,
      definition: definition
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

  @doc """
  The **storage tier** atom for a content type (D17): dynamic types store under
  the generic `:entry` tier, compiled types under their own atom. Accepts a
  registry descriptor, a type atom, or a public type-name string; returns `nil`
  for an unknown name. The single source of truth for firing/export/reindex
  callers that need the storage key from a public type.
  """
  @spec storage_type(t() | atom() | String.t(), Ash.UUID.t()) :: atom() | nil
  def storage_type(type_or_descriptor, org_id \\ KilnCMS.Accounts.default_org_id())
  def storage_type(%{source: :dynamic}, _org_id), do: :entry
  def storage_type(%{type: type}, _org_id), do: type
  def storage_type(type, _org_id) when is_atom(type), do: type

  def storage_type(type, org_id) when is_binary(type) do
    case get(type, org_id) do
      %{source: :dynamic} -> :entry
      %{type: atom} -> atom
      _ -> nil
    end
  end

  @doc ~S"""
  Find a content type by its public URL segment, e.g. "blog" or "products" —
  compiled first, then dynamic (`TypeDefinition.path_segment`).
  """
  @spec get_by_path(String.t(), Ash.UUID.t()) :: t() | nil
  def get_by_path(segment, org_id \\ KilnCMS.Accounts.default_org_id()) do
    Enum.find(all(), &(&1.path_segment == segment)) ||
      Enum.find(dynamic_all(org_id), &(&1.path_segment == segment))
  end

  @doc "The atom types of all content types."
  @spec types() :: [atom()]
  def types, do: Enum.map(all(), & &1.type)

  @doc """
  Look up a content type by its atom or string type. Returns nil if unknown.

  A string first resolves against compiled types (via `to_existing_atom`, so
  request data can't mint atoms), then against dynamic types by name —
  compiled always wins a name collision (which `TypeDefinition` validation
  prevents anyway). Atoms only ever name compiled types.
  """
  @spec get(atom() | String.t() | t() | nil, Ash.UUID.t()) :: t() | nil
  def get(type, org_id \\ KilnCMS.Accounts.default_org_id())

  def get(nil, _org_id), do: nil

  # An already-resolved descriptor passes through — iteration call sites hand
  # the descriptor straight to the dispatch helpers, so a type archived between
  # listing and dispatch can't turn into a lookup miss mid-request.
  def get(%{type: _} = descriptor, _org_id), do: descriptor

  # Atoms only ever name compiled types (org-independent).
  def get(type, _org_id) when is_atom(type), do: Enum.find(all(), &(&1.type == type))

  def get(type, org_id) when is_binary(type) do
    case safe_existing_atom(type) do
      nil -> get_dynamic(type, org_id)
      atom -> get(atom) || get_dynamic(type, org_id)
    end
  end

  @doc "Like `get/2` but raises for an unknown type (descriptors pass through)."
  @spec get!(atom() | String.t() | t(), Ash.UUID.t()) :: t()
  def get!(type, org_id \\ KilnCMS.Accounts.default_org_id()) do
    get(type, org_id) || raise ArgumentError, "unknown content type: #{inspect(type)}"
  end

  @doc "Whether `type` is a known content type."
  @spec type?(atom() | String.t()) :: boolean()
  def type?(type), do: not is_nil(get(type))

  # --- dispatch to the per-type code interfaces ------------------------------
  #
  # Each helper accepts a type atom or string and calls the
  # convention-named code interface on that type's own domain, e.g.
  # `KilnCMS.CMS.list_pages!/1` or `Verscienta.Catalog.list_herbs!/1`.
  #
  # Dynamic types route to the generic `Entry` interfaces (D17): `atom/1`
  # resolves them to `:entry` and `plural/1` to `"entries"`, so the same
  # convention dispatch lands on `CMS.publish_entry/…` — record-shaped helpers
  # (workflow, versions, restore, purge) need no branching at all. Only the
  # collection reads (scoped by `type_definition_id`) and `create!` (which
  # must stamp the type) branch explicitly.

  def list!(type, opts \\ []) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} -> CMS.list_entries!(scoped(opts, definition))
      _compiled -> call(type, "list_#{plural(type)}!", [opts])
    end
  end

  def get_record!(type, id, opts \\ []) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} -> CMS.get_entry!(id, scoped(opts, definition))
      _compiled -> call(type, "get_#{atom(type)}!", [id, opts])
    end
  end

  # Non-bang fetch by id (`{:ok, record} | {:error, _}`), e.g. for preview links.
  def get_record(type, id, opts \\ []) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} -> CMS.get_entry(id, scoped(opts, definition))
      _compiled -> call(type, "get_#{atom(type)}", [id, opts])
    end
  end

  # Public delivery: fetch a single published record by slug + locale (returns
  # nil rather than raising on a miss).
  def get_published_by_slug(type, slug, locale, opts \\ []) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} ->
        CMS.get_published_entry_by_slug!(slug, locale, definition.id, opts)

      _compiled ->
        call(type, "get_published_#{atom(type)}_by_slug!", [slug, locale, opts])
    end
  end

  # Every published locale variant of a slug (for hreflang / language switching).
  def list_translations(type, slug, opts \\ []) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} ->
        CMS.list_entry_translations!(slug, definition.id, opts)

      _compiled ->
        call(type, "list_#{atom(type)}_translations!", [slug, opts])
    end
  end

  def create!(type, attrs, opts \\ []) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} ->
        CMS.create_entry!(Map.put(attrs, :type_definition_id, definition.id), opts)

      _compiled ->
        call(type, "create_#{atom(type)}!", [attrs, opts])
    end
  end

  def list_versions!(type, opts \\ []), do: call(type, "list_#{atom(type)}_versions!", [opts])

  def restore_version(type, record, version_id, opts \\ []) do
    call(type, "restore_#{atom(type)}_version", [record, %{version_id: version_id}, opts])
  end

  @doc "Run a workflow transition: publish, unpublish, submit, archive, or unarchive."
  def transition(type, verb, record, opts \\ []) do
    call(type, transition_fun(atom(type), verb), [record, %{}, opts])
  end

  def list_trashed!(type, opts \\ []) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} ->
        CMS.list_trashed_entries!(scoped(opts, definition))

      _compiled ->
        call(type, "list_trashed_#{plural(type)}!", [opts])
    end
  end

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
  defp transition_fun(type, "unarchive"), do: "unarchive_#{type}"

  # Dynamic types resolve to the generic entry tier for interface naming, so
  # convention dispatch (`publish_entry`, `list_entry_versions!`, …) just works.
  defp atom(%{source: :dynamic}), do: :entry
  defp atom(%{type: type}), do: type
  defp atom(type) when is_atom(type), do: type

  defp atom(type) when is_binary(type) do
    case get!(type) do
      %{source: :dynamic} -> :entry
      ct -> ct.type
    end
  end

  defp plural(type) do
    case get!(type) do
      # The descriptor's `plural` is the human label ("Recipes"), not the
      # interface-name plural — entries share one interface set.
      %{source: :dynamic} -> "entries"
      ct -> ct.plural
    end
  end

  # The request org for resolving a dynamic type (epic #336): the `:tenant` opt
  # normalized to an `org_id` — an Organization struct (LiveView `current_org`), a
  # raw uuid (controllers), or nil → the sole org (the single-org rollout / any
  # tenant-less internal caller). So a dynamic type resolves under the writing
  # site, and the default keeps every existing caller working unchanged.
  defp org_from(opts) do
    case Keyword.get(opts, :tenant) do
      nil -> KilnCMS.Accounts.default_org_id()
      %{id: id} -> id
      id when is_binary(id) -> id
    end
  end

  # Scope an Entry code-interface call to one dynamic type. Internal callers
  # pass keyword `query`/`filter` opts (or none), so a keyword merge suffices.
  defp scoped(opts, definition) do
    query = Keyword.get(opts, :query, [])

    # Prepend a second :filter entry rather than Keyword-merging into the
    # caller's — Ash.Query.build applies every :filter (ANDed), and this stays
    # correct when the caller's filter is an expression, not a keyword list.
    Keyword.put(opts, :query, [{:filter, [type_definition_id: definition.id]} | query])
  end

  defp safe_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end
end
