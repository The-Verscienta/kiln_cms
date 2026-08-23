defmodule KilnCMS.CMS.Duplication do
  @moduledoc """
  "Duplicate this content" (#471) — the generic clone action behind the
  Duplicate button in the content list and the editor.

  A duplicate is a **new draft in the same locale**: title suffixed `(copy)`,
  the authored payload carried over (blocks, SEO title/description/image,
  excerpt, audience, custom fields, category, featured image, tags, related
  content), and everything that identifies or tracks the *source* left behind —

    * **slug** is not copied. Omitting it lets `Changes.DeriveSlug` regenerate
      one through the type's slug pattern (#454), deduped pathauto-style, so a
      second copy becomes `…-2` instead of colliding on the `[slug, locale]`
      identity;
    * **focus keyphrase** (`seo_keywords`) is not copied either. It is the one
      SEO field that is a *per-URL* target rather than a description of the
      body: two records chasing one keyphrase cannibalize each other, and
      because the default slug chain is keyphrase → title, carrying it would
      also mint the copy a slug with no relation to its title;
    * **workflow** starts at `:draft` — publish state, `scheduled_at` and
      `unpublish_at` never travel, so duplicating a published page can't put a
      half-edited copy on the site;
    * **history** starts fresh: the copy is a new document, not a new version
      of the source, and gets its own paper-trail from its create.

  Contrast `KilnCMS.CMS.Translations.create_translation!/4`, which clones the
  same payload the other way round — *keeping* the slug and changing the
  locale. Both share `KilnCMS.CMS.ContentCopy`.

  ## Related content

  Curated relations are cloned as `KilnCMS.CMS.ContentLink` **rows**, not
  through the `related_<type>_ids` argument. That argument is an id set, and
  `manage_relationship` would re-create every link with the resource defaults —
  flattening `kind`, `position`, `label` and the `metadata` payload that
  data-carrying relations (a formula → ingredient dosage, a "step N of") exist
  to hold, and collapsing two links to one target under different kinds into
  one. The rows are cloned after the copy is created, so a link failure leaves
  the copy behind rather than a half-written one; the copy is a draft, so that
  degrades to "re-add the relations", not to broken delivery.

  ## Authorization

  Duplication runs the type's ordinary `:create` action as the acting user, so
  create policies (`editable_types`, the write-scope checks, tenancy) apply
  exactly as they would to a hand-authored new document — there is no
  privileged path here.

  Per-field write grants (granular RBAC #332 slice 3) don't govern creates:
  `Changes.EnforceFieldGrants` deliberately skips them, because authoring a
  *new* document is gated by `editable_types` instead. Duplication is the one
  create that carries **another record's** values, though, so it honours the
  grant itself: a field-granted editor's copy carries only the attributes their
  grant names, and blocks only when the grant names `"blocks"` (mirroring how
  the change gates the headless `block_tree` argument).

  Two attributes are exempt from that filter, for opposite reasons. `title`,
  because the copy needs one to exist and the editor could type any title into
  a new document anyway. `audience`, because dropping it would fall back to the
  attribute default (`:public`) — strictly *less* restrictive than the source,
  which would quietly move a members-only body to the public tier.
  """

  require Logger

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentCopy
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Slugs

  # Appended to the source title. Not localized: it lands in a stored title
  # (and, through it, the slug) that outlives the acting editor's session
  # locale — a copy made by a French-speaking editor shouldn't read "(copie)"
  # to everyone else forever. Editors retitle the draft anyway.
  @copy_suffix " (copy)"

  # Carried whatever the acting editor's field grant says — see the module doc.
  # `title` is exempt for a different reason than `audience`: it is rewritten
  # rather than copied, so it is never withheld and must not be reported as
  # such.
  @grant_exempt_attrs [:title, :audience]

  @doc """
  Duplicate a record into a new draft of the same type and locale, raising on
  failure. Takes the record or just its id — the payload is re-read either way.
  `opts` are the usual `:actor` / `:tenant` (both expected — the create runs
  under the acting user's policies).
  """
  @spec duplicate!(atom() | String.t() | map(), struct() | Ash.UUID.t(), keyword()) :: struct()
  def duplicate!(kind, record_or_id, opts \\ []) do
    {copy, _withheld} = duplicate_with_notes!(kind, record_or_id, opts)
    copy
  end

  @doc """
  `duplicate!/3`, plus the list of things the copy did **not** carry.

  A copy is silently narrower than its source in two ways — a per-field write
  grant drops attributes, and a block-field policy resets values the actor could
  not have set — and the editor previously got "Duplicated as a new draft." with
  no hint either happened (#929). The caller needs both to say so.
  """
  @spec duplicate_with_notes!(atom() | String.t() | map(), struct() | Ash.UUID.t(), keyword()) ::
          {struct(), [String.t()]}
  def duplicate_with_notes!(kind, record_or_id, opts \\ []) do
    # Read the payload here rather than trusting what the caller had loaded:
    # the content list deliberately selects a handful of columns, so its rows
    # carry no blocks at all.
    load = ContentCopy.tag_load() ++ [:content_links]
    source = ContentTypes.get_record!(kind, id(record_or_id), Keyword.put(opts, :load, load))
    {attrs, withheld} = attrs(source, opts)

    # One transaction. The links used to be cloned after the create with nothing
    # tying them together, so a failure on link 12 of 40 left a COMMITTED copy
    # behind while the caller was told the duplicate failed and did not navigate
    # — three clicks, three orphan drafts, each with a partial link set (#925).
    {:ok, copy} =
      Ash.transaction(
        [
          Slugs.storage_resource(
            ContentTypes.get!(kind, KilnCMS.Accounts.org_id(Keyword.get(opts, :tenant)))
          )
        ],
        fn ->
          copy = ContentTypes.create!(kind, attrs, ContentCopy.create_opts(opts))
          clone_links(source, copy, opts)
          copy
        end
      )

    {copy, withheld}
  end

  @doc """
  `duplicate!/3` in the `{:ok, record} | {:error, reason}` shape, for UI
  callers that render a flash instead of crashing the LiveView.

  Anything other than a refusal (a policy denial, a validation error, a missing
  record) is logged before it is returned — the caller's flash cannot tell an
  outage from a permission check, so the log is the only place that difference
  survives.
  """
  @spec duplicate(atom() | String.t() | map(), struct() | Ash.UUID.t(), keyword()) ::
          {:ok, struct(), [String.t()]} | {:error, term()}
  def duplicate(kind, record_or_id, opts \\ []) do
    {copy, withheld} = duplicate_with_notes!(kind, record_or_id, opts)
    {:ok, copy, withheld}
  rescue
    error in [Ash.Error.Forbidden, Ash.Error.Query.NotFound] ->
      {:error, error}

    # `Invalid` is NOT a refusal, and it is the class a *copy* uniquely
    # produces: `ApplyCustomFields` re-validating an old value against today's
    # registry, `SeoUrls` on a copied `seo_image`, `PathAliasValid`. Grouping it
    # with the refusals meant support could not tell "you lack permission" from
    # "a stale custom-field value is unwriteable" — the flash is identical and
    # nothing reached the log.
    error ->
      Logger.warning("Duplicating #{inspect(kind)} content failed: #{Exception.message(error)}")
      {:error, error}
  end

  @doc "The title a duplicate of `title` gets — the source title, `(copy)` appended."
  @spec copy_title(String.t() | nil) :: String.t()
  def copy_title(title) do
    (title || "") |> String.trim() |> Kernel.<>(@copy_suffix) |> String.trim_leading()
  end

  defp id(%{id: id}), do: id
  defp id(id) when is_binary(id), do: id

  defp attrs(source, opts) do
    grant = ContentCopy.field_grant(source, opts)
    {copied, dropped} = ContentCopy.permitted(copyable_attrs(), grant, @grant_exempt_attrs)
    {blocks, reset_fields} = blocks(source, grant, opts)

    attrs =
      source
      |> ContentCopy.take(copied)
      |> Map.put(:title, copy_title(source.title))
      |> Map.put(:locale, source.locale)
      |> Map.put(:blocks, blocks)
      |> Map.put(:tag_ids, ContentCopy.tag_ids(source))

    # What the editor is told: attribute names the grant dropped, plus any block
    # field the block policy reset — both cases where the copy is narrower than
    # the source through no fault of the source. The exempt attrs are absent
    # because they were not withheld; the previous version derived this list
    # from `copyable_attrs()` without subtracting them, so an editor was told
    # `audience` had not been copied while the copy carried it (#1157 review).
    {attrs, dropped ++ reset_fields}
  end

  # The focus keyphrase stays with the source — see the module doc.
  defp copyable_attrs, do: ContentCopy.content_attrs() -- [:seo_keywords]

  # The acting tier decides which block fields survive: a value this role could
  # not have set is reset to its declared default rather than refused (#890).
  defp blocks(source, nil, opts), do: ContentCopy.dump_blocks(source, role: role(opts))

  defp blocks(source, allowed, opts) do
    if "blocks" in allowed,
      do: ContentCopy.dump_blocks(source, role: role(opts)),
      else: {[], ["blocks"]}
  end

  defp role(opts) do
    case Keyword.get(opts, :actor) do
      %{} = actor -> tier_or_nil(Scoping.effective_tier(actor, Keyword.get(opts, :tenant)))
      _ -> nil
    end
  end

  # `nil` means "unrestricted" to `ContentCopy` — an admin, or an actor-less
  # internal caller, matching the policy bypass.
  defp tier_or_nil(:admin), do: nil
  defp tier_or_nil(tier), do: tier

  # Re-point each of the source's outgoing links at the copy, payload intact.
  # `content_links` is the raw `ContentLink` row set (`kind`, `position`,
  # `label`, `metadata`); `incoming_links` deliberately stay with the source —
  # other records linked to *it*, not to a draft copy of it.
  defp clone_links(%{content_links: links}, copy, opts) when is_list(links) do
    scope = Keyword.take(opts, [:actor, :tenant])

    for link <- links do
      CMS.create_content_link!(
        %{
          source_id: copy.id,
          target_id: link.target_id,
          kind: link.kind,
          position: link.position,
          label: link.label,
          metadata: link.metadata
        },
        scope
      )
    end
  end

  defp clone_links(_source, _copy, _opts), do: []
end
