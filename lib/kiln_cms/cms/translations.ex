defmodule KilnCMS.CMS.Translations do
  @moduledoc """
  The **localization workflow** over per-locale content (D-i18n): content is
  modelled one record per locale sharing a slug (`unique [slug, locale]`), and
  this module answers the editorial questions that model raises —

    * `siblings/3` — every locale variant of a record (all workflow states,
      editor-facing; the public `published_translations` read stays the
      delivery surface);
    * `coverage/3` — per configured locale: the variant (or `:missing`), its
      workflow state, and whether it has gone **stale** (the default-locale
      source was updated after the translation's last edit — the standard
      lightweight outdated heuristic; any edit of the translation clears it);
    * `create_translation!/4` — one-click "translate to `<locale>`": duplicate
      the source's content fields into a new draft in the target locale, ready
      for a translator.

  All functions dispatch through `KilnCMS.CMS.ContentTypes`, so compiled types
  and admin-defined dynamic entries (D17) behave identically.
  """

  require Ash.Query

  alias KilnCMS.CMS.ContentCopy
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.I18n

  defmodule BlocksWithheldError do
    @moduledoc """
    Raised when an editor whose field grant excludes `blocks` tries to translate
    a document that has some (#1157).

    Refusing rather than creating an empty shell, because a translation is not
    a duplicate. It claims the `[slug, locale]` identity: the empty draft
    permanently occupies that locale, the one-click path is then dead for
    *everyone* (the create raises on the identity, and the UI hides the button
    for a locale that already exists), and the editor cannot fill it in
    afterwards — the same grant refuses their update. A duplicate gets a fresh
    slug and can simply be deleted; this cannot be undone by the person who did
    it.
    """
    defexception [:message]
  end

  # Content fields copied into a new translation: the payload every clone
  # carries (`ContentCopy`) plus the slug — a translation is the *same*
  # document in another locale, and the `[slug, locale]` identity is what pairs
  # them. Workflow (state, schedules) and delivery bookkeeping
  # (published_version, artifacts) start fresh; canonical_url is locale-specific
  # by nature, so it isn't carried over.
  @copied_attrs [:slug | ContentCopy.content_attrs()]

  # Carried whatever the acting editor's field grant says (#1157), each for its
  # own reason:
  #
  #   * `slug` — the `[slug, locale]` identity is what pairs a translation to
  #     its source. Dropping it doesn't narrow the copy, it stops the copy being
  #     a translation at all: the create would derive a fresh slug and mint an
  #     unrelated document in another locale.
  #   * `title` — the record needs one to exist, and the editor could type any
  #     title into a new document anyway.
  #   * `audience` — dropping it falls back to the attribute default
  #     (`:public`), which is strictly *less* restrictive than the source. A
  #     grant would silently move a members-only body to the public tier.
  #
  # `Duplication` exempts the same two it can (it rewrites `title` rather than
  # copying it), and states the same reasons.
  @grant_exempt_attrs [:slug, :title, :audience]

  @doc """
  Every locale variant sharing `record`'s slug (including `record` itself),
  any workflow state, sorted by locale. Editor-facing: pass the acting user.
  """
  @spec siblings(atom() | String.t() | map(), struct(), keyword()) :: [struct()]
  def siblings(kind, record, opts \\ []) do
    ContentTypes.list!(
      kind,
      Keyword.merge(opts, query: [filter: [slug: record.slug], sort: [locale: :asc]])
    )
  end

  @doc """
  Translation coverage for one record: an entry per configured locale —

      %{locale: "fr", record: %Page{} | nil, status: :published | :draft |
        :in_review | :archived | :missing, stale?: boolean()}

  `stale?` is true for a non-default-locale variant whose default-locale
  sibling was updated after it (never for the default locale or missing
  variants).
  """
  @spec coverage(atom() | String.t() | map(), struct(), keyword()) :: [map()]
  def coverage(kind, record, opts \\ []) do
    siblings = siblings(kind, record, opts)
    by_locale = Map.new(siblings, &{&1.locale, &1})
    source = by_locale[I18n.default_locale()]
    edited = edited_at(siblings, tenant: record.org_id)

    for locale <- I18n.locales() do
      variant = by_locale[locale]

      %{
        locale: locale,
        record: variant,
        status: if(variant, do: variant.state, else: :missing),
        stale?: stale?(variant, source, edited)
      }
    end
  end

  @doc """
  Whether `variant` is an outdated translation of `source`: the source was
  updated after the variant was last *edited*. Never for the default locale,
  a missing variant or a missing source.

  `edited` is `edited_at/2`'s map for the variants in question; a variant not
  in it is judged by its `updated_at`.
  """
  @spec stale?(struct() | nil, struct() | nil, %{optional(term()) => DateTime.t()}) :: boolean()
  def stale?(nil, _source, _edited), do: false
  def stale?(_variant, nil, _edited), do: false

  def stale?(variant, source, edited) do
    variant.locale != I18n.default_locale() and
      DateTime.after?(source.updated_at, Map.get(edited, variant.id, variant.updated_at))
  end

  @doc """
  When each record was last **edited**, by id: its `updated_at`, except for a
  variant field-level localization has copied shared values into (#1327).

  That copy (`:sync_shared_fields`) is a write, so it moves `updated_at` past
  the source's — and the outdated heuristic would read a translation nobody
  touched as freshly translated. For a record carrying such a copy in its
  history, the time is its newest version written by anything else. A record
  with none is untouched by this, so a site that shares nothing pays one
  version query per call.

  Pass `tenant:`. The version rows are read for records the caller already
  holds, and only their timestamps leave this function.
  """
  @spec edited_at([struct()], keyword()) :: %{optional(term()) => DateTime.t()}
  def edited_at([], _opts), do: %{}

  def edited_at([%resource{} | _] = records, opts) do
    version = Module.concat(resource, Version)
    tenant = Keyword.get(opts, :tenant)
    synced = synced_ids(version, Enum.map(records, & &1.id), tenant)

    if MapSet.size(synced) == 0 do
      Map.new(records, &{&1.id, &1.updated_at})
    else
      last_edits = last_edits(version, MapSet.to_list(synced), tenant)
      Map.new(records, &{&1.id, edit_time(&1, synced, last_edits)})
    end
  end

  defp edit_time(record, synced, last_edits) do
    if MapSet.member?(synced, record.id),
      do: Map.get(last_edits, record.id, record.inserted_at || record.updated_at),
      else: record.updated_at
  end

  # The records among `ids` that a shared-field copy has written.
  defp synced_ids(version, ids, tenant) do
    version
    |> Ash.Query.filter(version_source_id in ^ids and version_action_name == :sync_shared_fields)
    |> Ash.Query.select([:version_source_id])
    # authorize?: false — only version timestamps, of records the caller already read.
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> MapSet.new(& &1.version_source_id)
  end

  # Each record's newest version written by anything but that copy.
  defp last_edits(version, ids, tenant) do
    version
    |> Ash.Query.filter(version_source_id in ^ids and version_action_name != :sync_shared_fields)
    |> Ash.Query.select([:version_source_id, :version_inserted_at])
    # authorize?: false — only version timestamps, of records the caller already read.
    |> Ash.read!(tenant: tenant, authorize?: false)
    |> Enum.group_by(& &1.version_source_id, & &1.version_inserted_at)
    |> Map.new(fn {id, times} -> {id, Enum.max(times, DateTime)} end)
  end

  @doc """
  Create a draft translation of `record` in `target_locale`: same slug, the
  content fields copied (blocks included, dumped to their storage shape and
  re-cast), workflow starting at `:draft` with the acting user as author.
  Raises if the variant already exists (the `[slug, locale]` identity).
  """
  @spec create_translation!(atom() | String.t() | map(), struct(), String.t(), keyword()) ::
          struct()
  def create_translation!(kind, record, target_locale, opts \\ []) do
    {translation, _withheld} = create_translation_with_notes!(kind, record, target_locale, opts)
    translation
  end

  @doc """
  `create_translation!/4`, plus the list of things the translation did **not**
  carry.

  A translation can be silently narrower than its source in two ways — a
  per-field write grant drops attributes (#1157), and a block-field policy
  resets values the actor could not have set (#890) — and an editor told only
  "draft translation created" has no way to tell either from a bug. Same
  contract as `Duplication.duplicate_with_notes!/3`, for the same reason (#929).
  """
  @spec create_translation_with_notes!(
          atom() | String.t() | map(),
          struct(),
          String.t(),
          keyword()
        ) :: {struct(), [String.t()]}
  def create_translation_with_notes!(kind, record, target_locale, opts \\ []) do
    # Re-fetch with tags so the copy carries them regardless of what the
    # caller had loaded.
    record =
      ContentTypes.get_record!(kind, record.id, Keyword.put(opts, :load, ContentCopy.tag_load()))

    # Same role-aware reset as duplication: a block field this actor could not
    # have set is reset to its declared default rather than refused. Without it
    # an editor translating a page whose `quote` block has `featured: true` got
    # an error they could do nothing about — `EnforceBlockFieldPolicy` runs on
    # create, where there is no stored tree to diff against, so every admin-set
    # value trips it (#890).
    # `keep_ids?`: a locale variant is the same document in another language, so
    # its blocks keep the source's stable ids. That is what makes a paragraph
    # addressable across the pair — the XLIFF vendor round-trip (#502) matches
    # trans-units on block identity, and without shared ids it would have to
    # fall back to matching on position, which is wrong the moment either side
    # is reordered. See `ContentCopy.dump_blocks/2` for why sharing them is safe.
    grant = ContentCopy.field_grant(record, opts)
    {copied, dropped} = ContentCopy.permitted(@copied_attrs, grant, @grant_exempt_attrs)

    # Blocks follow the grant the way the `block_tree` argument does in
    # `Changes.EnforceFieldGrants`: a grant that does not name them does not
    # carry them. A translation of nothing is a poor answer, but it is the
    # honest one — the alternative hands an editor a document full of prose
    # they are refused, field by field, the moment they save it.
    {blocks, reset} = translated_blocks(record, grant, opts)

    attrs =
      record
      |> ContentCopy.take(copied)
      |> Map.put(:locale, target_locale)
      |> Map.put(:blocks, blocks)
      |> Map.put(:tag_ids, ContentCopy.tag_ids(record))

    {ContentTypes.create!(kind, attrs, ContentCopy.create_opts(opts)), dropped ++ reset}
  end

  defp translated_blocks(record, grant, opts) do
    cond do
      is_nil(grant) or "blocks" in grant ->
        # `keep_ids?`: see the comment above — a locale variant is the same
        # document, and the XLIFF round-trip matches trans-units on block id.
        ContentCopy.dump_blocks(record, role: role(opts), keep_ids?: true)

      # Nothing to withhold, so nothing to refuse: a source with no blocks
      # translates to a draft with no blocks either way.
      record.blocks in [nil, []] ->
        {[], []}

      true ->
        raise BlocksWithheldError,
          message: "your role cannot set blocks on this content type"
    end
  end

  defp role(opts) do
    case Keyword.get(opts, :actor) do
      %{} = actor ->
        case KilnCMS.Accounts.Scoping.effective_tier(actor, Keyword.get(opts, :tenant)) do
          :admin -> nil
          tier -> tier
        end

      _ ->
        nil
    end
  end
end
