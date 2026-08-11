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
          slug_pattern: String.t() | nil,
          alias_pattern: String.t() | nil,
          seo_title_pattern: String.t() | nil,
          seo_description_pattern: String.t() | nil,
          published_feed?: boolean(),
          source: :compiled | :dynamic,
          definition: struct() | nil
        }

  # First URL segments the router owns — a dynamic type's `path_segment` (its
  # public `/<segment>/<slug>` prefix) may not shadow any of these. Compiled
  # types' segments and configured locales are added at validation time (see
  # `Validations.AvailableTypeName`). Keep in sync with the top-level scopes in
  # `KilnCMSWeb.Router`.
  #
  # `feed.xml` / `feed.json` are here as *slug* guards rather than segment ones
  # (#486): the feed routes are `/:plural/feed.xml`, declared before the delivery
  # scope, so a record whose slug is `feed.xml` would be permanently shadowed by
  # its own type's feed — the silent-shadowing failure `Validations.SlugAvailable`
  # exists to prevent. `calendar.ics` (#480) and `index.json` (#766) are the same
  # shape: two-segment delivery routes declared ahead of `/:type/:slug`.
  @reserved_path_segments ~w(account admin api auth billing blog calendar.ics
                             content dev editor feed.json feed.xml gql index.json
                             locale mailbox media membership playground preview
                             register reset search sign_in swaggerui up)

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
  # `TypeDefinition` belongs to one site. `org` defaults to the sole org so
  # every tenant-less caller keeps working under the single-org rollout; the
  # delivery/editor hot paths thread the request's real org. Cached per-org (the
  # key carries the id), so one site's types never leak into another's.
  #
  # Takes a whole `Organization` as readily as an id (#527). Every caller holds
  # one or the other, and requiring the id here is what grew ten private
  # `org_id/1` copies at the call sites — one of which then had to be right
  # about `nil`, and they weren't. Normalizing here means a caller cannot get
  # it wrong, and `KilnCMS.Accounts.org_id/1` raises on anything that isn't an
  # org rather than reading someone else's id as a tenant.
  @spec dynamic_all(KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) :: [t()]
  def dynamic_all(org \\ nil) do
    org_id = KilnCMS.Accounts.org_id(org)

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

  @doc """
  Whether type-registry-derived answers may be cached.

  Off in tests: the cache is a global Cachex key while test sandboxes are
  per-test, so a cached registry would leak one test's types into another —
  as a *phantom* type, since the row it describes has been rolled back.

  Public because this registry is not the only thing derived from it.
  `KilnCMS.Feeds.syndicated_types/1` caches a filtered copy of the same
  descriptors, `%TypeDefinition{}` structs and all, and has to honour the same
  switch or it reintroduces the leak one layer up.
  """
  @spec cache_registry?() :: boolean()
  def cache_registry? do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(:cache_registry?, true)
  end

  @doc """
  Every content type available to an organization: the compiled ones, then its
  admin-defined ones (#527).

  `all() ++ dynamic_all(...)` appeared at ~20 call sites, each re-deriving the
  org id from whatever it was holding. `org` may be an `Organization`, a bare
  id, or `nil` — see `KilnCMS.Accounts.org_id/1` for why `nil` resolves to the
  default org rather than raising.

  Order is compiled-then-dynamic, each half sorted by label — the order every
  one of those call sites already produced, and the order the grouped
  "Built-in"/"Custom" pickers render in.
  """
  @spec all_for_org(KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) :: [t()]
  def all_for_org(org), do: all() ++ dynamic_all(KilnCMS.Accounts.org_id(org))

  @doc """
  Every content type available to `org` as `{label, name string}` select options
  (#527).

  Seven admin pick-lists built this by hand, and they had already diverged: six
  rendered `all_for_org/1`'s compiled-then-dynamic order while `taxonomy_live`
  re-sorted across the seam, so the same list appeared in two different orders in
  the same console — and, in the field-definition form, in two different orders
  on the same page, next to a picker grouped "Built-in" then "Custom". This
  settles all of them on `all_for_org/1`'s order.

  `:prompt` prepends a `{label, value}` pair for the callers that lead with an
  "any"/"all" entry. Note that it shifts every index by one — don't read a
  default out of this list by position.
  """
  @spec options(KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil, keyword()) ::
          [{String.t(), String.t()}]
  def options(org, opts \\ []) do
    types = org |> all_for_org() |> Enum.map(&{&1.label, to_string(&1.type)})

    case Keyword.get(opts, :prompt) do
      nil -> types
      prompt -> [prompt | types]
    end
  end

  @doc """
  Look up a dynamic content type by its name string, within `org` — an
  `Organization`, an id, or `nil` for the sole org (epic #336). Returns nil if
  unknown.
  """
  @spec get_dynamic(String.t(), KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) ::
          t() | nil
  def get_dynamic(name, org \\ nil) when is_binary(name),
    do: Enum.find(dynamic_all(org), &(&1.type == name))

  @doc "Router-owned first URL segments a dynamic type may not use."
  @spec reserved_path_segments() :: [String.t()]
  def reserved_path_segments, do: @reserved_path_segments

  @doc """
  The grant/registry key for a **record or changeset** — the dynamic type's own
  name for an `Entry`, and the compiled type's name otherwise.

  `type_name/1` takes a resource *module*, which is all a compiled type needs.
  Every admin-defined type shares one module (`KilnCMS.CMS.Entry`), so asking
  the module yields `"entry"` for all of them — and a per-type key resolved that
  way silently collapses. That is not merely a lost lookup: `Scoping.field_grant/3`
  reads `nil` as **no restriction**, so a grant of `{"recipe": ["title"]}` was
  the opposite of what the admin configured (#927).

  Falls back to `type_name/1` when the record names no dynamic type, so a caller
  can use this unconditionally.
  """
  @spec type_name_for(struct() | Ash.Changeset.t()) :: String.t() | nil
  def type_name_for(%Ash.Changeset{} = changeset) do
    dynamic_name(
      changeset.resource,
      Ash.Changeset.get_attribute(changeset, :type_definition_id),
      changeset.tenant || Ash.Changeset.get_attribute(changeset, :org_id)
    )
  end

  def type_name_for(%resource{} = record),
    do: dynamic_name(resource, Map.get(record, :type_definition_id), Map.get(record, :org_id))

  def type_name_for(_other), do: nil

  defp dynamic_name(resource, nil, _org), do: type_name(resource)

  defp dynamic_name(resource, definition_id, org) do
    org
    |> dynamic_all()
    |> Enum.find(&(&1.definition.id == definition_id))
    |> case do
      %{type: name} -> name
      # An id the registry does not know (a type deleted mid-request, or a
      # cache that has not caught up) falls back rather than raising — the
      # caller then sees the generic key, which is what it saw before.
      nil -> type_name(resource)
    end
  rescue
    _error -> type_name(resource)
  end

  @doc """
  The public content-type name for a resource module, or `nil` for resources
  outside the content macro. The single authority the RBAC scope checks
  compare against (granular RBAC #332) — one place to change when the
  `__kiln_content_type__` contract evolves.

  AshPaperTrail version twins (`<Source>.Version`) resolve to their **source**
  resource's type name, so scope checks treat a document's history as the same
  type as the document (a version's `changes` carry the full draft snapshot).
  """
  @spec type_name(module()) :: String.t() | nil
  def type_name(resource) when is_atom(resource) do
    cond do
      not Code.ensure_loaded?(resource) ->
        nil

      function_exported?(resource, :__kiln_content_type__, 0) ->
        to_string(resource.__kiln_content_type__())

      source = version_source(resource) ->
        to_string(source.__kiln_content_type__())

      true ->
        nil
    end
  end

  # `Module.concat(source, Version)` is how AshPaperTrail names the twin.
  defp version_source(resource) do
    with parts when length(parts) > 1 <- Module.split(resource),
         "Version" <- List.last(parts),
         source = parts |> Enum.drop(-1) |> Module.concat(),
         true <- function_exported?(source, :__kiln_content_type__, 0) do
      source
    else
      _ -> nil
    end
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
      section: resource.__kiln_content_section__(),
      excerpt?: not is_nil(Ash.Resource.Info.attribute(resource, :excerpt)),
      path_segment: path_segment(type, plural),
      # Guarded like the shared marker probe, so a resource compiled against
      # an older macro (stale beam, external :content_domains) degrades to
      # "no pattern" instead of crashing the whole registry.
      slug_pattern:
        if(function_exported?(resource, :__kiln_content_slug_pattern__, 0),
          do: resource.__kiln_content_slug_pattern__()
        ),
      alias_pattern:
        if(function_exported?(resource, :__kiln_content_alias_pattern__, 0),
          do: resource.__kiln_content_alias_pattern__()
        ),
      seo_title_pattern:
        if(function_exported?(resource, :__kiln_seo_title_pattern__, 0),
          do: resource.__kiln_seo_title_pattern__()
        ),
      seo_description_pattern:
        if(function_exported?(resource, :__kiln_seo_description_pattern__, 0),
          do: resource.__kiln_seo_description_pattern__()
        ),
      # Compiled types (Page/Post) all have a public index of published records;
      # a dynamic type says so per type (#486 reads this to decide syndication).
      published_feed?: true,
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
      slug_pattern: definition.slug_pattern,
      alias_pattern: definition.alias_pattern,
      seo_title_pattern: definition.seo_title_pattern,
      seo_description_pattern: definition.seo_description_pattern,
      published_feed?: definition.has_published_feed,
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
  Whether a content resource is served at the site root (`/<slug>`, no type
  prefix). The dynamic entry tier has no content-type markers and is never
  root-served (dynamic types always get a `path_segment`).
  """
  @spec root_served?(module()) :: boolean()
  def root_served?(resource) do
    Code.ensure_loaded?(resource) and function_exported?(resource, :__kiln_content_type__, 0) and
      is_nil(path_segment(resource.__kiln_content_type__(), resource.__kiln_content_plural__()))
  end

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
  @spec get_by_path(String.t(), KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) ::
          t() | nil
  def get_by_path(segment, org \\ nil) do
    Enum.find(all(), &(&1.path_segment == segment)) ||
      Enum.find(dynamic_all(org), &(&1.path_segment == segment))
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
  @spec get(
          atom() | String.t() | t() | nil,
          KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil
        ) :: t() | nil
  def get(type, org \\ nil)

  def get(nil, _org), do: nil

  # An already-resolved descriptor passes through — iteration call sites hand
  # the descriptor straight to the dispatch helpers, so a type archived between
  # listing and dispatch can't turn into a lookup miss mid-request.
  def get(%{type: _} = descriptor, _org), do: descriptor

  # Atoms only ever name compiled types (org-independent).
  def get(type, _org) when is_atom(type), do: Enum.find(all(), &(&1.type == type))

  def get(type, org) when is_binary(type) do
    case safe_existing_atom(type) do
      nil -> get_dynamic(type, org)
      atom -> get(atom) || get_dynamic(type, org)
    end
  end

  @doc "Like `get/2` but raises for an unknown type (descriptors pass through)."
  @spec get!(atom() | String.t() | t(), KilnCMS.Accounts.Organization.t() | Ash.UUID.t() | nil) ::
          t()
  def get!(type, org \\ nil) do
    get(type, org) || raise ArgumentError, "unknown content type: #{inspect(type)}"
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
      _compiled -> call(type, "list_#{plural(type, opts)}!", [opts], opts)
    end
  end

  def get_record!(type, id, opts \\ []) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} -> CMS.get_entry!(id, scoped(opts, definition))
      _compiled -> call(type, "get_#{atom(type, opts)}!", [id, opts], opts)
    end
  end

  # Non-bang fetch by id (`{:ok, record} | {:error, _}`), e.g. for preview links.
  def get_record(type, id, opts \\ []) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} -> CMS.get_entry(id, scoped(opts, definition))
      _compiled -> call(type, "get_#{atom(type, opts)}", [id, opts], opts)
    end
  end

  # Public delivery: fetch a single published record by slug + locale (returns
  # nil rather than raising on a miss).
  #
  # `:audiences` (#337 Phase 2) widens the read to gated content the caller has
  # already established the reader holds; `:unlocks` (#496) widens it to locked
  # content the caller holds a verified grant for. Popped from `opts` into the
  # action's params, so every existing caller — which passes neither — keeps the
  # public, unlocked behaviour exactly.
  def get_published_by_slug(type, slug, locale, opts \\ []) do
    {params, opts} = audience_params(opts)

    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} ->
        CMS.get_published_entry_by_slug!(slug, locale, definition.id, params, opts)

      _compiled ->
        call(
          type,
          "get_published_#{atom(type, opts)}_by_slug!",
          [slug, locale, params, opts],
          opts
        )
    end
  end

  # Locate a GATED published record in order to render a paywall for a reader who
  # may not read it. Returns a projection that never carries the block tree — see
  # the `:teaser_by_slug` action and `KilnCMSWeb.Teaser`.
  def get_teaser_by_slug(type, slug, locale, opts \\ []) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} ->
        CMS.get_entry_teaser_by_slug!(slug, locale, definition.id, opts)

      _compiled ->
        call(type, "get_#{atom(type, opts)}_teaser_by_slug!", [slug, locale, opts], opts)
    end
  end

  # Locate a LOCKED published record (#496) in order to render its passphrase
  # form, or to verify a submitted passphrase. Like the teaser, the projection
  # never carries the block tree — see the `:locked_by_slug` action.
  def get_locked_by_slug(type, slug, locale, opts \\ []) do
    {audiences, opts} = Keyword.pop(opts, :audiences, [])
    params = %{audiences: audiences}

    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} ->
        CMS.get_locked_entry_by_slug!(slug, locale, definition.id, params, opts)

      _compiled ->
        call(type, "get_locked_#{atom(type, opts)}_by_slug!", [slug, locale, params, opts], opts)
    end
  end

  # `:audiences` widens the read across the audience axis; `:unlocks` widens it
  # across the passphrase axis (#496). Both default to "nothing extra", so a
  # caller that passes neither reads exactly what an anonymous visitor may:
  # published, `:public`, unlocked.
  defp audience_params(opts) do
    {audiences, opts} = Keyword.pop(opts, :audiences, [])
    {unlocks, opts} = Keyword.pop(opts, :unlocks, [])
    {%{audiences: audiences, unlocks: unlocks}, opts}
  end

  # Every published locale variant of a slug (for hreflang / language switching).
  # Takes the same `:audiences` widening as `get_published_by_slug/4`.
  def list_translations(type, slug, opts \\ []) do
    {params, opts} = audience_params(opts)

    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} ->
        CMS.list_entry_translations!(slug, definition.id, params, opts)

      _compiled ->
        call(type, "list_#{atom(type, opts)}_translations!", [slug, params, opts], opts)
    end
  end

  def create!(type, attrs, opts \\ []) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} ->
        CMS.create_entry!(Map.put(attrs, :type_definition_id, definition.id), opts)

      _compiled ->
        call(type, "create_#{atom(type, opts)}!", [attrs, opts], opts)
    end
  end

  @doc "Generic update through the type's own code interface (primary `:update`)."
  def update(type, record, attrs, opts \\ []),
    do: call(type, "update_#{atom(type, opts)}", [record, attrs, opts], opts)

  def list_versions!(type, opts \\ []),
    do: call(type, "list_#{atom(type, opts)}_versions!", [opts], opts)

  def restore_version(type, record, version_id, opts \\ []) do
    call(
      type,
      "restore_#{atom(type, opts)}_version",
      [record, %{version_id: version_id}, opts],
      opts
    )
  end

  @doc "Run a workflow transition: publish, unpublish, submit, archive, or unarchive."
  def transition(type, verb, record, opts \\ []) do
    call(type, transition_fun(atom(type, opts), verb), [record, %{}, opts], opts)
  end

  def list_trashed!(type, opts \\ []) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic, definition: definition} ->
        CMS.list_trashed_entries!(scoped(opts, definition))

      _compiled ->
        call(type, "list_trashed_#{plural(type, opts)}!", [opts], opts)
    end
  end

  def restore(type, record, opts \\ []),
    do: call(type, "restore_#{atom(type, opts)}", [record, %{}, opts], opts)

  def purge(type, record, opts \\ []),
    do: call(type, "purge_#{atom(type, opts)}", [record, opts], opts)

  def destroy(type, record, opts \\ []),
    do: call(type, "destroy_#{atom(type, opts)}", [record, opts], opts)

  # --- internals -------------------------------------------------------------

  # Resolve a convention-built interface name to the existing function on the
  # type's domain and call it. `to_existing_atom` (not interpolation) keeps this
  # safe for request-derived types — the code interfaces are defined at compile
  # time.
  defp call(type, fun_name, args, opts) do
    apply(domain_for(type, opts), String.to_existing_atom(fun_name), args)
  end

  # Resolved under the CALLER's org, not the default one. A dynamic type belongs
  # to an organization, so looking it up without the tenant raised "unknown
  # content type" for every admin-defined type outside the default org — and
  # because `transition/4`'s only caller wrapped it in a rescue, an import under
  # `--org staging` created every record and then silently left each one a draft
  # while reporting it published (#972).
  defp domain_for(type, opts), do: get!(type, org_from(opts)).domain

  defp transition_fun(type, "publish"), do: "publish_#{type}"
  defp transition_fun(type, "unpublish"), do: "unpublish_#{type}"
  defp transition_fun(type, "submit"), do: "submit_#{type}_for_review"
  defp transition_fun(type, "return"), do: "return_#{type}_to_draft"
  defp transition_fun(type, "archive"), do: "archive_#{type}"
  defp transition_fun(type, "unarchive"), do: "unarchive_#{type}"

  # Dynamic types resolve to the generic entry tier for interface naming, so
  # convention dispatch (`publish_entry`, `list_entry_versions!`, …) just works.
  defp atom(%{source: :dynamic}, _opts), do: :entry
  defp atom(%{type: type}, _opts), do: type
  defp atom(type, _opts) when is_atom(type), do: type

  # Only the binary clause needs a lookup, and so only it needs the org — but
  # that is the dynamic-type clause, which is exactly the one that was resolving
  # against the default org.
  defp atom(type, opts) when is_binary(type) do
    case get!(type, org_from(opts)) do
      %{source: :dynamic} -> :entry
      ct -> ct.type
    end
  end

  defp plural(type, opts) do
    case get!(type, org_from(opts)) do
      # The descriptor's `plural` is the human label ("Recipes"), not the
      # interface-name plural — entries share one interface set.
      %{source: :dynamic} -> "entries"
      ct -> ct.plural
    end
  end

  # The request org for resolving a dynamic type (epic #336): the `:tenant` opt
  # normalized to an org id. `KilnCMS.Accounts.org_id/1` is that normalization —
  # this used to restate it, including the loose `%{id: id}` clause #527 exists
  # to prevent, which quietly accepts a `User`, a `Page` or a socket and hands
  # its id downstream as a tenant, where it surfaces not as an error but as an
  # empty registry.
  defp org_from(opts), do: KilnCMS.Accounts.org_id(Keyword.get(opts, :tenant))

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
