defmodule KilnCMS.CMS.Changes.RefuseTrashed do
  @moduledoc """
  Refuses an update on a content row that is in the trash (#2332). The
  decision, the alternatives rejected and the exemption policy are in
  `docs/decisions/0052-a-trashed-content-row-refuses-every-update-by-default-through-a-row-filter.md`.

  Trashing is a soft delete (AshArchival): it stamps `archived_at` and the
  archival read preparation hides the row from every ordinary read. It does
  nothing for updates. An editor, an API client, or a background job that
  loaded the record before someone trashed it still holds the struct, and an
  update built from that struct used to write straight into the trashed
  row: an autosave, a *Publish changes* that re-fired the artifacts and sent
  an `updated` webhook after the `deleted` one, a transition, a held
  oEmbed refresh.

  Registered once, `on: [:update]`, in the content resources' `changes`
  block, so every update action refuses by default and the next one added
  does too. It adds a filter on the ROW, `is_nil(archived_at)`, a
  compare-and-swap like the workflow transitions' state filters. Not a
  validation and not a policy: either would judge the struct the caller
  holds, which was loaded before the trash, so the race this exists for
  would pass it (see the comment on `:autosave` in `KilnCMS.CMS.Content`).
  A miss raises `Ash.Error.Changes.StaleRecord`, which the editors already
  read as "this content changed elsewhere" and the APIs answer as
  not-found. A background job (`KilnCMS.Search.EmbeddingWorker`, the oEmbed
  `ResolveWorker`) caught in the read-to-write race sees the same error and
  retries; the retry re-reads, finds no record, and ends `:ok`.

  One gap: a bulk update run with the stream strategy whose changeset
  changes nothing returns the record without consulting the filter, so a
  no-op bulk write on a trashed row is not reported as refused. It writes
  nothing either.

  Exempt (`exempt_actions/0`), with the reason for each:

    * `:restore`: taking a row out of the trash is its whole purpose. It
      carries the opposite filter (the row must still be trashed) so a
      second restore of a held struct is refused.
    * `:clear_reference_target`: a purge clears the purged record out of
      every referrer's `:reference` fields inside its transaction
      (`KilnCMS.CMS.ContentLinks.TargetDelete`), trashed referrers
      included, or a restored referrer would still name a record that no
      longer exists. It fires and announces only a referrer that is not
      trashed.
    * `:convert_custom_field` and `:resnapshot_media`: the backfills a
      contract step relies on (`KilnCMS.CMS.FieldConversion`,
      `KilnCMS.Media.Resnapshot`) walk the trash too, or a row trashed
      before the step and restored after the contract release would come
      back with the old field shape or a stale media snapshot (#2533). Each
      fires only when the row its write returned is out of the trash
      (`Changes.FireArtifacts`, `skip_trashed: true`): a trashed row's
      artifacts were purged when it was trashed.

  Not exempt, deliberately: `:set_next_occurrence`. The value it writes is
  relative to the clock, so one written into a trashed row is stale again by
  the time the row is restored; `:restore` recomputes it instead (#2621).
  """
  use Ash.Resource.Change

  require Ash.Expr

  @exempt [:restore, :clear_reference_target, :convert_custom_field, :resnapshot_media]

  @doc "The update actions allowed to write a trashed row. See the moduledoc."
  @spec exempt_actions() :: [atom()]
  def exempt_actions, do: @exempt

  @impl true
  def change(%Ash.Changeset{action: %{name: name}} = changeset, _opts, _context)
      when name in @exempt,
      do: changeset

  def change(changeset, _opts, _context) do
    attribute = AshArchival.Resource.Info.archive_attribute!(changeset.resource)
    Ash.Changeset.filter(changeset, Ash.Expr.expr(is_nil(^Ash.Expr.ref(attribute))))
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
