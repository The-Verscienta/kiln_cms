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

  # Appended to the source title. Not localized: it lands in a stored title
  # (and, through it, the slug) that outlives the acting editor's session
  # locale — a copy made by a French-speaking editor shouldn't read "(copie)"
  # to everyone else forever. Editors retitle the draft anyway.
  @copy_suffix " (copy)"

  # Carried whatever the acting editor's field grant says — see the module doc.
  # (`title` is exempt too, but it is rewritten rather than copied.)
  @grant_exempt_attrs [:audience]

  @doc """
  Duplicate a record into a new draft of the same type and locale, raising on
  failure. Takes the record or just its id — the payload is re-read either way.
  `opts` are the usual `:actor` / `:tenant` (both expected — the create runs
  under the acting user's policies).
  """
  @spec duplicate!(atom() | String.t() | map(), struct() | Ash.UUID.t(), keyword()) :: struct()
  def duplicate!(kind, record_or_id, opts \\ []) do
    # Read the payload here rather than trusting what the caller had loaded:
    # the content list deliberately selects a handful of columns, so its rows
    # carry no blocks at all.
    load = ContentCopy.tag_load() ++ [:content_links]
    source = ContentTypes.get_record!(kind, id(record_or_id), Keyword.put(opts, :load, load))

    copy = ContentTypes.create!(kind, attrs(source, opts), opts)
    clone_links(source, copy, opts)

    copy
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
          {:ok, struct()} | {:error, term()}
  def duplicate(kind, record_or_id, opts \\ []) do
    {:ok, duplicate!(kind, record_or_id, opts)}
  rescue
    error in [Ash.Error.Forbidden, Ash.Error.Invalid, Ash.Error.Query.NotFound] ->
      {:error, error}

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
    allowed = allowed_fields(source, opts)

    source
    |> ContentCopy.take(copied_attrs(allowed))
    # After `take/2`: these carry regardless of the grant (see the module doc),
    # and the title is the one attribute the copy rewrites rather than clones.
    |> Map.merge(ContentCopy.take(source, @grant_exempt_attrs))
    |> Map.put(:title, copy_title(source.title))
    |> Map.put(:locale, source.locale)
    |> Map.put(:blocks, blocks(source, allowed))
    |> Map.put(:tag_ids, ContentCopy.tag_ids(source))
  end

  # The focus keyphrase stays with the source — see the module doc.
  defp copyable_attrs, do: ContentCopy.content_attrs() -- [:seo_keywords]

  defp copied_attrs(nil), do: copyable_attrs()

  defp copied_attrs(allowed),
    do: Enum.filter(copyable_attrs(), &(to_string(&1) in allowed))

  defp blocks(source, nil), do: ContentCopy.dump_blocks(source)

  defp blocks(source, allowed),
    do: if("blocks" in allowed, do: ContentCopy.dump_blocks(source), else: [])

  # `nil` means "copy everything" — no grant restriction applies. A list is the
  # attribute names the acting editor may write for this type. Effective admins
  # (and actor-less internal callers) are exempt, mirroring the policy bypass
  # `Changes.EnforceFieldGrants` respects.
  defp allowed_fields(source, opts) do
    actor = Keyword.get(opts, :actor)
    subject = Keyword.get(opts, :tenant)

    with %{} <- actor,
         :editor <- Scoping.effective_tier(actor, subject) do
      Scoping.field_grant(actor, subject, ContentTypes.type_name(source.__struct__))
    else
      _ -> nil
    end
  end

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
