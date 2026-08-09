defmodule KilnCMS.CMS.ContentSerializer do
  @moduledoc """
  Serializes a Page/Post into a plain map of public fields — used by the
  preview endpoint and webhook payloads. Internal fields (e.g. `search_text`)
  are never included.

  ## `audience` and `locked` ride along, and that is the point (#1014)

  A webhook fires for an audience-gated or passphrase-locked document exactly as
  it does for a public one, carrying the full block tree. That is defensible — an
  endpoint is somewhere an operator deliberately sends content, HMAC-signed and
  SSRF-guarded, unlike the anonymously-queryable Meilisearch index (#1006) — but
  it was not *knowable*: the payload said nothing about either gate, so a
  subscriber mirroring publishes onto a public front end had nothing to filter on
  and no way to discover the problem.

  `KilnCMS.Federation.AnnounceWorker` had already written the complaint down —
  the payload "does not carry `audience` at all — the single most important field
  for deciding whether something may be federated" — and re-reads the live record
  rather than trusting it.

  **Both halves, because one is not enough.** Kiln's own rule for "may an
  anonymous visitor read this" is three-part and fails closed
  (`KilnCMS.CMS.Audiences.public_to_anonymous?/1`): published, `:public`, and no
  passphrase. Shipping `audience` alone would let a receiver reproduce two thirds
  of it and quietly mirror a locked document — published `:public`, then locked
  afterwards, arrives here as `"audience" => "public"` with the whole body.

  `locked` is a derived boolean, never the hash or the `password_fingerprint`.
  The anti-enumeration rule that keeps #496 from disclosing *which* documents are
  locked defends an anonymous surface (`docs/threat-model.md`); this sink is
  operator-chosen and already holds the body it would be enumerating, so
  withholding the flag here protects nothing and makes correct filtering
  impossible.

  Both are additive, so no subscriber breaks; `state` was already here for the
  same reason.

  ## `effective_seo_*` beside the stored fields, not instead of them (#1102)

  A content type can default its `seo_title` / `seo_description` from a pattern
  (#805), resolved when the page is rendered and never written to the column. A
  payload carrying only the column therefore disagreed with the page it
  describes: a preview showed a blank description for a document whose
  `<meta name="description">` had a sentence in it, and a subscriber mirroring
  publishes onto its own front end reproduced the blank.

  Both spellings ship, because they answer different questions.
  `seo_description` is what a human typed — blank means *nobody wrote one*,
  which is what the editor's SEO panel and the export (#487) read it as, and
  overwriting it here would reimport as an author-typed override.
  `effective_seo_description` is what a renderer should print. Additive, like
  the two above.

  Read, never resolved: `KilnCMS.Seo.Patterns.effective/3` is called with
  `resolve: false`, so it reports the loaded calculation where a caller asked for
  one — the preview endpoint does — and the stored column otherwise. It must not
  reach the type registry here, because `Changes.NotifyWebhooks` builds this
  payload in an `after_action`, inside the publishing transaction: a query that
  fails there aborts the commit and the record is lost, which is a bad trade for
  a field on a notification.

  So a webhook payload can still carry a stored blank where the page carries the
  type's default. That is a smaller gap than the one #1102 closed — the field is
  present, additive, and correct on every surface that reads through a query —
  and closing it properly means moving the dispatch to `after_transaction`, which
  is a change to when a webhook fires, not to what it says.
  """

  alias KilnCMS.Seo.Patterns

  @public_fields [
    :id,
    :title,
    :slug,
    :excerpt,
    :blocks,
    :seo_title,
    :seo_description,
    :seo_keywords,
    :seo_image,
    :canonical_url,
    :locale,
    :state,
    # Not decoration: a subscriber cannot tell a members-only document from a
    # public one without it, and the payload carries the whole body either way.
    :audience,
    :published_at,
    :scheduled_at,
    :inserted_at,
    :updated_at
  ]

  @block_fields [:type, :content, :data, :order, :children]

  @doc "Curated public map for a Page/Post record."
  @spec to_map(struct()) :: map()
  def to_map(record) do
    record
    |> Map.take(@public_fields)
    |> Map.update(:blocks, [], fn blocks ->
      blocks |> List.wrap() |> Enum.map(&Map.take(&1, @block_fields))
    end)
    |> Map.put(:locked, locked?(record))
    |> Map.put(:effective_seo_title, Patterns.effective(record, :seo_title, resolve: false))
    |> Map.put(
      :effective_seo_description,
      Patterns.effective(record, :seo_description, resolve: false)
    )
  end

  # Derived, so the hash never leaves — see the moduledoc.
  #
  # Fails CLOSED on anything that is not plainly "no hash": an unselected
  # attribute arrives as `%Ash.NotLoaded{}`, and reading that as "not locked"
  # would be the one wrong answer. A record with no such attribute at all is a
  # resource without the feature, which is genuinely not locked.
  defp locked?(record) do
    case Map.get(record, :access_password_hash, :absent) do
      nil -> false
      :absent -> false
      _hash_or_unloaded -> true
    end
  end
end
