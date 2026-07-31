defmodule KilnCMS.CMS.Changes.AnchorVersion do
  @moduledoc """
  Extends the tamper-evident anchor chain after **every** versioned write, not
  only at publish (#356).

  Anchors minted at publish leave everything written between two publishes
  covered only retroactively — the window `KilnCMS.Governance.Chain` reports
  as `unanchored_tail/2`. With `audit_anchor_every_write: true` each save
  closes that window immediately: the write's own version is folded onto the
  previous anchor's recorded hash and signed.

  Runs in `after_transaction` so the PaperTrail version row exists to fold.
  Publish actions are skipped — `KilnCMS.CMS.Changes.RecordPublishedVersion`
  already anchors those, and its anchor additionally records
  `published_version_id`, so anchoring here too would add a duplicate row
  covering the same versions.

  Off by default, and `Chain.extend/2` never raises: an anchoring problem must
  not cost an editor their save.
  """
  use Ash.Resource.Change

  alias KilnCMS.Governance.Chain

  @publish_actions [:publish, :publish_scheduled]

  # Actions PaperTrail is told to ignore (`ignore_actions` in the shared
  # `paper_trail` block) write no version, so there is nothing to fold. Worse,
  # `:set_published_version_id` runs *inside* the publish pipeline's
  # after_transaction — anchoring it would consume the publish's own version
  # and leave `RecordPublishedVersion` with nothing to record, dropping the
  # `published_version_id` linkage from the anchor.
  @versionless_actions [:set_embedding, :set_published_version_id]

  @impl true
  def change(changeset, _opts, context) do
    if skip?(changeset) do
      changeset
    else
      actor_id = context.actor && context.actor.id

      Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
        extend(result, actor_id)
      end)
    end
  end

  defp extend({:ok, record} = result, actor_id) do
    Chain.extend(record, actor_id: actor_id)
    result
  end

  defp extend(result, _actor_id), do: result

  # Cheap gates first: don't attach a hook at all when the feature is off or
  # the publish pipeline owns this write.
  defp skip?(changeset) do
    not Chain.every_write?() or not Chain.enabled?() or
      changeset.action.name in @publish_actions or
      changeset.action.name in @versionless_actions
  end
end
