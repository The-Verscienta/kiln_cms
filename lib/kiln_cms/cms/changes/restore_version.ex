defmodule KilnCMS.CMS.Changes.RestoreVersion do
  @moduledoc """
  Restores a Page/Post's content fields to the state captured at a given
  PaperTrail version.

  Versions are tracked in `:changes_only` mode (each stores only what changed),
  so the full state at the target version is reconstructed by folding every
  version's `changes` from creation up to and including the target —
  `KilnCMS.CMS.VersionSnapshot`, shared with the version-compare UI (#467). The
  restore itself is captured as a new version.

  ## What moves

  Every editorial attribute the compare view reports, less workflow and
  attribution — the list is `KilnCMS.CMS.VersionFields.restorable_fields/1`, and
  it is derived from the same declaration the diff is, so the two can't drift
  apart again (#691). Values are force-changed rather than accepted, so the
  action takes no content input of its own; `Changes.EnforceFieldGrants` refuses
  the verb outright to a field-granted editor, because no param inspection can
  scope a write that never passed through params.

  ### A field the fold never wrote is restored to its default, not skipped

  `:changes_only` records an attribute only on the write that changed it, so a
  field first set *after* the target version has no key in the fold at all —
  and a field that predates its own migration has no key in any version below
  it. Leaving those alone is what #691 was filed about: the compare view reports
  `SEO title: — → Added later` and offers Restore, and the SEO title does not
  move. So an absent key restores the attribute's **default** (`nil` where there
  isn't one), which is exactly the value the record carried at that instant.

  ### `custom_fields` restores wholesale

  The stored map replaces the current one, so a key added after the target
  version is gone afterwards. That is what the compare view promises — it
  reports such a key as *added* between the two versions — and a key-wise merge
  would make that report a lie. The map is written as it was stored, bypassing
  `Changes.ApplyCustomFields`, so a definition retired since leaves a key the
  editor form no longer renders; routing a restored map back through the
  registry is tracked separately (#708).

  ## References

  `category_id` and `featured_image_id` restore as raw ids, and the record they
  named may be gone. Rather than write a dangling reference (or half-restore the
  document and say nothing), a restore whose reference this org can no longer
  read fails with a field error naming the relationship.

  Every non-nil restored reference is checked, including one the record already
  carries. Skipping the unchanged ones would read the id off `changeset.data` —
  a caller-supplied struct that the editor LiveView holds across a whole session
  — so a reference another editor moved and trashed in the meantime would sail
  past the check on a stale comparison.

  The pairs aren't listed here: they're every `belongs_to` whose source attribute
  is restorable, read off the resource, so a future relationship is covered
  without a second list to forget.

  ## Re-validation

  Ash validations run while the changeset is built, and these writes land in a
  `before_action` hook — so a value from history reaches the row after every
  `validate` on the action has already passed. The ones that guard a *stored*
  value rather than user input are therefore re-run by hand once the fold has
  been applied: history is full of values that were legal when written and are
  not now (a `path_alias` another record has since claimed, a `canonical_url`
  predating `Validations.SeoUrls`).
  """
  use Ash.Resource.Change
  require Ash.Query

  alias KilnCMS.CMS.Validations
  alias KilnCMS.CMS.VersionFields
  alias KilnCMS.CMS.VersionSnapshot

  # Guard stored values, so a fold can violate them; re-run after the restore.
  # `ScheduleOrder` is deliberately absent — the schedule isn't restorable.
  @revalidate [
    Validations.SlugAvailable,
    Validations.PathAliasValid,
    Validations.SeoUrls
  ]

  @impl true
  def change(changeset, _opts, context) do
    version_id = Ash.Changeset.get_argument(changeset, :version_id)
    Ash.Changeset.before_action(changeset, &apply_version(&1, version_id, context))
  end

  defp apply_version(changeset, version_id, context) do
    version_module = Module.concat(changeset.resource, Version)
    source_id = changeset.data.id
    # Version twins are tenant-strict (#419) — reads carry the record org.
    org_id = changeset.data.org_id
    restorable = VersionFields.restorable_fields(changeset.resource)

    with {:ok, target} <- fetch_target(version_module, version_id, source_id, org_id),
         {:ok, state} <-
           VersionSnapshot.at(version_module, source_id, target,
             authorize?: false,
             tenant: org_id
           ) do
      changeset
      |> restore_fields(state, restorable)
      |> revalidate(context)
      |> revalidate_alt_text(context)
      |> revalidate_claims(context)
      |> validate_references(restorable, org_id)
    else
      :error ->
        Ash.Changeset.add_error(changeset,
          field: :version_id,
          message: "is not a version of this record"
        )
    end
  end

  defp fetch_target(version_module, version_id, source_id, org_id) do
    version_module
    |> Ash.Query.filter(id == ^version_id and version_source_id == ^source_id)
    |> Ash.read_one(authorize?: false, tenant: org_id)
    |> case do
      {:ok, %{} = version} -> {:ok, version}
      _ -> :error
    end
  end

  defp restore_fields(changeset, state, restorable) do
    Enum.reduce(restorable, changeset, fn name, acc ->
      # Values arrive in the shape PaperTrail stored (JSON), which
      # `force_change_attribute/3` casts back.
      value = Map.get_lazy(state, to_string(name), fn -> default(acc.resource, name) end)
      Ash.Changeset.force_change_attribute(acc, name, value)
    end)
  end

  # The value the attribute held before anything wrote it — which is what the
  # record carried at a version whose fold has no key for it.
  defp default(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      %{default: fun} when is_function(fun, 0) -> fun.()
      %{default: {module, function, args}} -> apply(module, function, args)
      %{default: value} -> value
      nil -> nil
    end
  end

  # ── Re-validation ─────────────────────────────────────────────────────────

  defp revalidate(changeset, context) do
    Enum.reduce(@revalidate, changeset, fn module, acc ->
      case module.validate(acc, [], context) do
        :ok -> acc
        {:error, error} -> Ash.Changeset.add_error(acc, error)
      end
    end)
  end

  # Restoring `blocks` onto a PUBLISHED record can ship an alt-less image just
  # as an ordinary edit can (#722). This action force-changes blocks in a
  # `before_action`, so the publish gate (a plain `validate`) never sees them —
  # re-run it by hand after the fold, like the `@revalidate` set. Gated on the
  # record being published, since a draft restore makes no public claim and
  # `state` isn't restorable, so `changeset.data.state` is the effective state.
  defp revalidate_alt_text(changeset, context) do
    if changeset.data.state == :published do
      # `only_new: true`, like the `:update` gate: a restore that reintroduces an
      # image already live undescribed is not this write's doing, but one that
      # brings back an undescribed image the current page had fixed is refused.
      case Validations.MediaAltText.validate(changeset, [only_new: true], context) do
        :ok -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    else
      changeset
    end
  end

  # Exactly the same hole for claim checking (#377): this action force-changes
  # `blocks`, `title`, `seo_title` and `seo_description` in a `before_action`,
  # so the plain `validate` on `:update` has already run, and `:restore_version`
  # fires artifacts of its own when the record is published. Restoring a live
  # page to a version that said "FDA approved" would put the claim back on the
  # public site having passed no gate at all.
  #
  # `only_new: true` for the same reason as above: restoring a claim that is
  # already live is not this write's doing.
  defp revalidate_claims(changeset, context) do
    if changeset.data.state == :published do
      case Validations.ComplianceClaims.validate(changeset, [only_new: true], context) do
        :ok -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    else
      changeset
    end
  end

  # ── References ────────────────────────────────────────────────────────────

  defp validate_references(changeset, restorable, org_id) do
    changeset.resource
    |> Ash.Resource.Info.relationships()
    |> Enum.filter(&(&1.type == :belongs_to and &1.source_attribute in restorable))
    |> Enum.reduce(changeset, &check_reference(&2, &1, org_id))
  end

  defp check_reference(changeset, relationship, org_id) do
    id = Ash.Changeset.get_attribute(changeset, relationship.source_attribute)

    cond do
      is_nil(id) ->
        changeset

      reference_exists?(relationship, id, org_id) ->
        changeset

      true ->
        Ash.Changeset.add_error(changeset,
          field: relationship.source_attribute,
          message: "from that version no longer exists"
        )
    end
  end

  # Through the destination's primary read, so a soft-deleted record reads as
  # gone: an archived media item's row survives, and the FK would accept it, but
  # restoring a featured image the editor has trashed just puts a broken hero
  # back on the page. Deliberately unrescued — an unreadable destination or a
  # dropped connection is not evidence that the record was deleted, and
  # answering "no longer exists" to a pool timeout tells the editor to go hunting
  # for an image that is sitting in the media library.
  defp reference_exists?(relationship, id, org_id) do
    destination_attribute = relationship.destination_attribute

    relationship.destination
    |> Ash.Query.filter(^ref(destination_attribute) == ^id)
    |> Ash.exists?(authorize?: false, tenant: org_id)
  end
end
