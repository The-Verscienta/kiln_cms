defmodule KilnCMS.CMS.Slugs do
  @moduledoc """
  Pathauto-style URL helpers for content records.

  `public_path/2` assembles the full public path for a record — the type's
  delivery prefix plus the slug (`/blog/guide-kiln` for a post, `/about` for a
  root-served page) — from `ContentTypes.public_prefix/1`, the same authority
  the delivery routes use.

  `ensure_unique/2` returns the first collision-free variant of a derived slug
  (`base`, then `base-2`, `base-3`, …), scoped exactly like the `unique_slug`
  identity (locale, org, and `type_definition_id` on the dynamic entry tier).
  Root-served types additionally treat router-owned first segments and every
  other content type's URL prefix as taken (`taken_root_segments/1`), so a
  derived slug can never mint an unreachable URL — a page slugged "blog"
  would be permanently shadowed by the `/blog` section by route order.
  """

  require Ash.Query

  alias KilnCMS.CMS.ContentTypes

  @doc "Full public path for a type descriptor + slug (`/blog/guide-kiln`, `/about`)."
  @spec public_path(ContentTypes.t(), String.t() | nil) :: String.t()
  def public_path(ct, slug), do: ContentTypes.public_prefix(ct) <> "/" <> to_string(slug || "")

  @doc """
  A record's **canonical** public path: its multi-segment `path_alias` (#485)
  when set, else the flat type prefix + slug.
  """
  @spec public_path_for(ContentTypes.t(), struct()) :: String.t()
  def public_path_for(ct, record),
    do: Map.get(record, :path_alias) || public_path(ct, record.slug)

  # The storage tables aliases live on: every compiled content resource plus
  # the shared dynamic entry tier.
  defp alias_resources do
    Enum.uniq(Enum.map(ContentTypes.all(), & &1.resource) ++ [KilnCMS.CMS.Entry])
  end

  @doc "Whether another record (any type/state) already holds `alias_path` in `locale`."
  @spec alias_taken?(String.t(), String.t() | nil, term(), Ash.UUID.t() | nil) :: boolean()
  def alias_taken?(alias_path, locale, tenant, exclude_id) do
    Enum.any?(alias_resources(), fn resource ->
      resource
      |> Ash.Query.select([:id])
      |> Ash.Query.filter(path_alias == ^alias_path)
      |> maybe_filter(:locale, locale)
      |> exclude_record(exclude_id)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false, tenant: tenant)
      |> Kernel.!=([])
    end)
  end

  @doc """
  The published record canonically served at `alias_path` (#485), as
  `{descriptor, record}` — the delivery fallback's alias lookup. Mirrors the
  `:public_by_slug` boundary, including its `:audiences` widening (#337 Phase 2):
  `audiences` defaults to `[]`, so a caller that passes none sees `:public` rows
  only, exactly as before.
  """
  @spec find_published_by_alias(String.t(), String.t(), Ash.UUID.t(), [atom()], [String.t()]) ::
          {ContentTypes.t(), struct()} | nil
  def find_published_by_alias(alias_path, locale, org_id, audiences \\ [], unlocks \\ []) do
    Enum.find_value(alias_resources(), fn resource ->
      resource
      |> Ash.Query.filter(
        path_alias == ^alias_path and locale == ^locale and state == :published and
          (audience == :public or audience in ^audiences) and
          (is_nil(access_password_hash) or password_fingerprint in ^unlocks)
      )
      |> Ash.Query.load([:author, :category])
      |> first_with_descriptor(org_id)
    end)
  end

  @doc """
  The LOCKED published record at `alias_path`, for a passphrase form (#496).

  Sibling of `find_teaser_by_alias/3` and shaped the same way: it *requires* a
  passphrase to be set, so it can never stand in for the entitled lookup, and it
  selects only lock-page-safe columns — never the block tree. Takes `audiences`
  because the lock is ANDed with the audience axis (see the delivery funnel).
  """
  @spec find_locked_by_alias(String.t(), String.t(), Ash.UUID.t(), [atom()]) ::
          {ContentTypes.t(), struct()} | nil
  def find_locked_by_alias(alias_path, locale, org_id, audiences \\ []) do
    Enum.find_value(alias_resources(), fn resource ->
      resource
      |> Ash.Query.filter(
        path_alias == ^alias_path and locale == ^locale and state == :published and
          (audience == :public or audience in ^audiences) and
          not is_nil(access_password_hash)
      )
      |> Ash.Query.select(lock_columns(resource))
      |> first_with_descriptor(org_id)
    end)
  end

  @doc """
  The GATED published record at `alias_path`, for a paywall teaser (#337 Phase 2).

  A sibling rather than a mode flag on `find_published_by_alias/4`, mirroring the
  two separate content actions: it *requires* a non-public audience, so it can
  never stand in for the entitled lookup, and it selects only paywall-safe
  columns — never the block tree.
  """
  @spec find_teaser_by_alias(String.t(), String.t(), Ash.UUID.t()) ::
          {ContentTypes.t(), struct()} | nil
  def find_teaser_by_alias(alias_path, locale, org_id) do
    Enum.find_value(alias_resources(), fn resource ->
      resource
      |> Ash.Query.filter(
        path_alias == ^alias_path and locale == ^locale and state == :published and
          audience != :public
      )
      |> Ash.Query.select(teaser_columns(resource))
      |> first_with_descriptor(org_id)
    end)
  end

  # The lock-page column set: the teaser's, plus the stored hash the unlock
  # endpoint verifies against and the fingerprint it mints a grant from. Mirrors
  # the `:locked_by_slug` action's select — still without the block tree.
  defp lock_columns(resource),
    do: teaser_columns(resource) ++ [:access_password_hash, :password_fingerprint]

  # The paywall-safe column set for a resource — `:excerpt` only where the type
  # opted into it. Mirrors the `:teaser_by_slug` action's select.
  defp teaser_columns(resource) do
    base = [
      :id,
      :org_id,
      :title,
      :slug,
      :locale,
      :audience,
      :state,
      :seo_title,
      :seo_description,
      :seo_image,
      :canonical_url,
      :path_alias,
      :published_at,
      :updated_at
    ]

    Enum.filter(base ++ [:excerpt, :type_definition_id], fn field ->
      not is_nil(Ash.Resource.Info.attribute(resource, field))
    end)
  end

  defp first_with_descriptor(query, org_id) do
    record =
      query
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false, tenant: org_id)
      |> List.first()

    with %{} = record <- record,
         ct when not is_nil(ct) <- descriptor_for_record(record) do
      {ct, record}
    else
      _ -> nil
    end
  end

  # The default derivation as a pattern: the focus keyphrase, which itself
  # falls back to the title (see Pattern.token_value/2).
  @default_pattern "[focus-keyphrase]"

  @doc """
  The derivation base for a record: its type's slug pattern (#454) when one is
  set, else the default chain (focus keyphrase → title). The **single** entry
  point for both `Changes.DeriveSlug` and the editor's live sync, so the slug
  previewed live is always the slug that saves.

  Two guard rails:

    * no usable author text (title/keyphrase slugify to `""`) → `""`, so a
      date-token pattern can't mint meaningless slugs like `2026-07` from an
      unsluggable title — the caller leaves the slug blank and the required
      validation speaks;
    * a pattern that expands to `""` for this record (e.g. `[category]` on an
      uncategorized entry) falls back to the default chain instead of failing
      the write.
  """
  @spec derive_base(String.t() | nil, KilnCMS.Slug.Pattern.context(), [Kiln.Tokens.definition()]) ::
          String.t()
  def derive_base(pattern, context, extra \\ []) do
    # The default chain is built-ins only by construction — it is this module's
    # own literal — so it never needs a type's extra tokens.
    default = KilnCMS.Slug.Pattern.expand(@default_pattern, context)

    cond do
      default == "" ->
        ""

      is_nil(pattern) ->
        default

      true ->
        case KilnCMS.Slug.Pattern.expand(pattern, context, extra) do
          "" -> default
          base -> base
        end
    end
  end

  @doc "The storage resource behind a registry descriptor (dynamic types → the entry tier)."
  @spec storage_resource(ContentTypes.t()) :: module()
  def storage_resource(%{source: :dynamic}), do: KilnCMS.CMS.Entry
  def storage_resource(%{resource: resource}), do: resource

  @doc """
  The registry descriptor for a **stored** content record: dynamic entries
  resolve through their `type_definition_id`, compiled records through their
  resource's type marker. `nil` when the type is no longer registered.
  """
  @spec descriptor_for_record(struct()) :: ContentTypes.t() | nil
  def descriptor_for_record(record) do
    org_id = Map.get(record, :org_id) || KilnCMS.Accounts.default_org_id()

    case record do
      %{type_definition_id: definition_id} when not is_nil(definition_id) ->
        Enum.find(
          ContentTypes.dynamic_all(org_id),
          &(&1.definition && &1.definition.id == definition_id)
        )

      %struct{} ->
        case ContentTypes.type_name(struct) do
          nil -> nil
          type -> ContentTypes.get(type, org_id)
        end
    end
  end

  @doc """
  Pattern-expansion context (`Pattern.context/0`) from a **stored** record
  (category loaded or absent). The date anchor is the same chain everywhere:
  publish date, else scheduled date, else the record's creation date.
  """
  @spec record_context(struct()) :: KilnCMS.Slug.Pattern.context()
  def record_context(record) do
    %{
      title: record.title,
      seo_keywords: Map.get(record, :seo_keywords),
      category_slug: record_category_slug(record),
      slug: record.slug,
      custom_fields: Map.get(record, :custom_fields),
      date: record.published_at || record.scheduled_at || Map.get(record, :inserted_at)
    }
  end

  defp record_category_slug(%{category: %{slug: slug}}), do: slug
  defp record_category_slug(_record), do: nil

  @doc """
  Pattern-expansion context from a **changeset being written** — the same
  keys and date-anchor chain as `record_context/1`, shared by `DeriveSlug`
  and `DeriveAlias`. The category read runs only when the pattern actually
  mentions `[category]`.
  """
  @spec changeset_context(Ash.Changeset.t(), String.t() | nil) :: KilnCMS.Slug.Pattern.context()
  def changeset_context(changeset, pattern) do
    %{
      title: Ash.Changeset.get_attribute(changeset, :title),
      seo_keywords: changeset_attribute(changeset, :seo_keywords),
      category_slug: changeset_category_slug(changeset, pattern),
      slug: Ash.Changeset.get_attribute(changeset, :slug),
      custom_fields: changeset_custom_fields(changeset, pattern),
      # Stable date anchor: publish date when set, else the scheduled date,
      # else the record's creation date (nil on create → today, which then IS
      # the creation date). Never re-read from the wall clock afterwards.
      date:
        Ash.Changeset.get_attribute(changeset, :published_at) ||
          Ash.Changeset.get_attribute(changeset, :scheduled_at) ||
          Map.get(changeset.data, :inserted_at)
    }
  end

  @doc "get_attribute/2, but nil when the resource lacks the attribute."
  @spec changeset_attribute(Ash.Changeset.t(), atom()) :: term()
  def changeset_attribute(changeset, name) do
    if Ash.Resource.Info.attribute(changeset.resource, name),
      do: Ash.Changeset.get_attribute(changeset, name)
  end

  @doc """
  The type's slug or alias pattern for a changeset: compiled types carry
  theirs as compile-time markers; dynamic entries resolve theirs with one
  keyed read of their TypeDefinition row (the row id is globally unique, so
  this is tenant-correct even though the org_id attribute isn't materialized
  until after action changes run).
  """
  @spec pattern_for(Ash.Changeset.t(), :slug | :alias) :: String.t() | nil
  def pattern_for(changeset, kind) do
    resource = changeset.resource
    marker = marker_for(kind)

    if Code.ensure_loaded?(resource) and function_exported?(resource, marker, 0) do
      apply(resource, marker, [])
    else
      dynamic_pattern(changeset, kind)
    end
  end

  defp marker_for(:slug), do: :__kiln_content_slug_pattern__
  defp marker_for(:alias), do: :__kiln_content_alias_pattern__

  defp dynamic_pattern(changeset, kind) do
    with definition_id when not is_nil(definition_id) <-
           changeset_attribute(changeset, :type_definition_id),
         {:ok, definition} <-
           KilnCMS.CMS.get_type_definition(definition_id,
             authorize?: false,
             tenant: changeset.tenant
           ) do
      case kind do
        :slug -> definition.slug_pattern
        :alias -> definition.alias_pattern
      end
    else
      _ -> nil
    end
  end

  defp changeset_category_slug(changeset, pattern) do
    with true <- KilnCMS.Slug.Pattern.uses?(pattern, "category"),
         category_id when not is_nil(category_id) <-
           changeset_attribute(changeset, :category_id),
         {:ok, category} <-
           KilnCMS.CMS.get_category(category_id, authorize?: false, tenant: changeset.tenant) do
      category.slug
    else
      _ -> nil
    end
  end

  # The custom-field values a `[field:<name>]` token resolves against.
  #
  # For an editable field the raw payload carries the value, so it is read
  # straight off the changeset. A `:computed` field (#601) has none — the write
  # pass derives it in `Changes.ApplyCustomFields`, which runs AFTER slug/alias
  # derivation, so the token would otherwise read an empty value on create and a
  # one-save-stale value on update (#616). Derive any computed field the pattern
  # references here, fresh, through the same evaluator the write pass uses.
  #
  # Value parity with the write pass holds for a formula over the document (the
  # common `{{ slugify(title) }}` case); a formula referencing a *sibling*
  # editable field sees that field pre-coercion here (raw payload) versus
  # post-coercion at write time, so a number posted as a string can slugify
  # differently. That is the known tradeoff of resolving on demand rather than
  # reordering the whole write pass.
  #
  # Bounded: the definitions read and evaluation happen only when the pattern
  # actually carries a `[field:…]` token — a plain `[title]` slug pays nothing.
  # (An editable-only `[field:…]` pattern still pays one definitions read to
  # learn it has no computed fields; the value it reads is unchanged.)
  defp changeset_custom_fields(changeset, pattern) do
    raw = changeset_attribute(changeset, :custom_fields)

    case KilnCMS.Slug.Pattern.field_names(pattern) do
      [] -> raw
      referenced -> merge_computed_fields(changeset, referenced, raw)
    end
  end

  defp merge_computed_fields(changeset, referenced, raw) do
    # String keys, matching what the write pass evaluates against and what the
    # `[field:<name>]` token itself looks up — an atom-keyed payload from an
    # Elixir/MCP caller would otherwise miss its own sibling fields.
    base = stringify_keys(raw)

    computed =
      changeset
      |> field_definitions()
      |> Enum.filter(&(&1.field_type == :computed and &1.name in referenced))

    case computed do
      [] ->
        base

      defs ->
        # Drop the computed keys before deriving, so a formula that now
        # evaluates blank reads as ABSENT (the token expands to "") rather than
        # as the stale stored value `raw` still carries on an update — the write
        # pass builds its map from scratch and so never leaks a stale value.
        cleared = Map.drop(base, Enum.map(defs, & &1.name))
        context = KilnCMS.CMS.Computed.Context.from_changeset(changeset, cleared)
        derive_into(defs, context, cleared)
    end
  end

  defp derive_into(defs, context, fields) do
    Enum.reduce(defs, fields, fn definition, acc ->
      case KilnCMS.CMS.Computed.evaluate(definition.compute || "", context) do
        blank when blank in [nil, ""] -> acc
        value -> Map.put(acc, definition.name, value)
      end
    end)
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_keys(_not_a_map), do: %{}

  # The FieldDefinition rows for the changeset's content type — compiled types by
  # their content-type marker, dynamic entries by their TypeDefinition id. Mirror
  # of `ApplyCustomFields`'s own lookup; kept private since only the computed-slug
  # path here needs it.
  @doc """
  The extra `Kiln.Tokens` definitions the custom field types attached to
  `field_definitions` contribute (#804).

  `[field:<name>]` already slugifies any scalar custom-field value for free, and
  expands a map or list one to `""`. That is the honest answer for most types
  and the wrong one for a **composite**: a coordinate pair or a
  price-and-currency wants to expose its own named parts
  (`[field:location.lat]`) rather than go blank. `c:Kiln.FieldType.tokens/1` is
  where a type says so; this is what asks it.

  Core field types have no module (the host coerces them) and contribute
  nothing. A plugin type that hand-rolls `@behaviour Kiln.FieldType` without
  the callback contributes nothing either — `tokens/1` is an optional callback,
  so it is probed rather than assumed.
  """
  @spec type_token_definitions([struct()]) :: [Kiln.Tokens.definition()]
  def type_token_definitions(field_definitions) do
    Enum.flat_map(field_definitions, fn definition ->
      case KilnCMS.CMS.FieldTypes.get(definition.field_type) do
        nil -> []
        module -> type_tokens(module, definition)
      end
    end)
  end

  defp type_tokens(module, definition) do
    if function_exported?(module, :tokens, 1) do
      module.tokens(definition)
    else
      []
    end
  rescue
    # A plugin's token list must not be able to fail a save. A slug derivation
    # that raised here would take down the write it was decorating, and the
    # token simply expanding empty is the same outcome the generic
    # `[field:<name>]` path already gives a value it cannot render.
    _error -> []
  end

  @doc """
  Extra token definitions for a pattern being expanded on `changeset`, or `[]`.

  Gated on the pattern actually mentioning a token the built-in vocabulary does
  not cover, which is almost never — so the field-definition read this needs is
  not paid for by the overwhelming majority of slug derivations.
  """
  @spec changeset_token_definitions(Ash.Changeset.t(), String.t() | nil, atom()) ::
          [Kiln.Tokens.definition()]
  def changeset_token_definitions(changeset, pattern, usage) do
    case KilnCMS.Slug.Pattern.unknown_tokens(pattern, usage) do
      [] -> []
      _unknown -> changeset |> field_definitions() |> type_token_definitions()
    end
  end

  defp field_definitions(%{resource: resource} = changeset) do
    tenant = changeset.to_tenant

    if function_exported?(resource, :__kiln_dynamic_entry__, 0) do
      case changeset_attribute(changeset, :type_definition_id) do
        nil -> []
        id -> KilnCMS.CMS.field_definitions_for_definition!(id, authorize?: false, tenant: tenant)
      end
    else
      KilnCMS.CMS.field_definitions_for!(resource.__kiln_content_type__(),
        authorize?: false,
        tenant: tenant
      )
    end
  end

  @doc """
  Whether `slug` is still auto-derived relative to `derived` (the current
  `derive_base/2` output): an `untitled-…` scaffold, an exact match, or a
  dedupe variant. `ensure_unique/2` never mints `-1`, so a `-1` suffix (or any
  non-matching base) means the author chose the slug; `base-N` with N >= 2
  stays ambiguous by construction and we side with "still derived".
  """
  @spec underived?(String.t() | nil, String.t()) :: boolean()
  def underived?(slug, derived) do
    slug = slug || ""

    scaffold?(slug) or (derived != "" and slug == derived) or
      dedupe_variant?(slug, derived)
  end

  # Both scaffold shapes, because both exist in the wild. `untitled-<digits>` is
  # what every draft created before #834 carries and those rows do not migrate;
  # `untitled-<random_suffix>` is what new ones get. Recognising only the new
  # one would strand every existing draft with a slug a title edit can no longer
  # replace — the same bug as recognising only the old one, aimed backwards.
  defp scaffold?("untitled-" <> rest),
    do: Regex.match?(~r/\A\d+\z/, rest) or KilnCMS.Slug.random_suffix?(rest)

  defp scaffold?(_slug), do: false

  defp dedupe_variant?(_slug, ""), do: false

  defp dedupe_variant?(slug, derived) do
    case Regex.run(~r/\A#{Regex.escape(derived)}-(\d+)\z/, slug, capture: :all_but_first) do
      [n] -> String.to_integer(n) >= 2
      _ -> false
    end
  end

  @doc "`ensure_unique/2` options for a stored record of type `ct`."
  @spec unique_scope(ContentTypes.t(), struct(), term()) :: keyword()
  def unique_scope(ct, record, tenant) do
    [
      resource: storage_resource(ct),
      root?: is_nil(ct.path_segment),
      type_definition_id: ct.definition && ct.definition.id,
      locale: record.locale,
      org_id: Map.get(record, :org_id),
      tenant: tenant,
      exclude_id: record.id
    ]
  end

  @doc """
  First URL segments a **root-served** slug may not use: segments the router
  owns plus every content type's public prefix (compiled + the org's dynamic
  types) — a root `/<slug>` equal to any of these is unreachable.
  """
  @spec taken_root_segments(Ash.UUID.t()) :: [String.t()]
  def taken_root_segments(org_id) do
    compiled = Enum.map(ContentTypes.all(), & &1.path_segment)
    dynamic = Enum.map(ContentTypes.dynamic_all(org_id), & &1.path_segment)

    Enum.reject(ContentTypes.reserved_path_segments() ++ compiled ++ dynamic, &is_nil/1)
  end

  @doc """
  The first variant of `base` whose URL is free: `base`, then `base-2`,
  `base-3`, … (pathauto-style dedupe).

  Options:

    * `:resource` (required) — the storage resource to check against
    * `:locale`, `:org_id`, `:type_definition_id` — uniqueness scope; `nil`
      values are skipped (matching the `unique_slug` identity fields present
      on the resource)
    * `:exclude_id` — the record being edited, so its own saved slug doesn't
      count as a collision
    * `:tenant` — passed through to the read (strict tenancy)
    * `:root?` — also avoid `taken_root_segments/1` (root-served types)
  """
  @spec ensure_unique(String.t(), keyword()) :: String.t()
  def ensure_unique(base, opts) when is_binary(base) and base != "" do
    root =
      if Keyword.get(opts, :root?, false),
        do: taken_root_segments(opts[:org_id] || KilnCMS.Accounts.default_org_id()),
        else: []

    taken = MapSet.new(existing_variants(base, opts) ++ root)

    [base]
    |> Stream.concat(Stream.map(2..1_000, &"#{base}-#{&1}"))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
    # Past a thousand variants, give up on a tidy number and take a random one.
    # `System.unique_integer/1` was wrong here for the reason #834 documents —
    # it resets on VM restart while the rows do not — and wrong in the worst
    # place: this branch is reached only when the low numbers are already taken,
    # which is exactly the range a restarted counter hands back out.
    |> Kernel.||("#{base}-#{KilnCMS.Slug.random_suffix()}")
  end

  # Every existing slug that could collide with `base` or its numbered
  # variants, in one indexed read per tier (rather than an exists?-query per
  # candidate). Trashed rows count as taken too: the `unique_slug` index spans
  # them, so a slug held by a soft-deleted record would fail the write even
  # though the default read can't see it.
  defp existing_variants(base, opts) do
    resource = Keyword.fetch!(opts, :resource)

    live = read_variants(Ash.Query.new(resource), base, opts)

    trashed =
      case Ash.Resource.Info.action(resource, :trashed) do
        nil -> []
        _action -> read_variants(Ash.Query.for_read(resource, :trashed), base, opts)
      end

    live ++ trashed
  end

  defp read_variants(query, base, opts) do
    query
    |> Ash.Query.select([:slug])
    |> Ash.Query.filter(like(slug, ^(base <> "%")))
    |> maybe_filter(:locale, opts[:locale])
    |> maybe_filter(:org_id, opts[:org_id])
    |> maybe_filter(:type_definition_id, opts[:type_definition_id])
    |> exclude_record(opts[:exclude_id])
    |> Ash.read!(authorize?: false, tenant: opts[:tenant])
    |> Enum.map(& &1.slug)
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field, value),
    do: Ash.Query.filter(query, ^Ash.Expr.ref(field) == ^value)

  defp exclude_record(query, nil), do: query
  defp exclude_record(query, id), do: Ash.Query.filter(query, id != ^id)
end
