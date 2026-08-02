defmodule KilnCMS.CMS.VersionFields do
  @moduledoc """
  The one declaration of which content attributes version history covers, and
  which of them a restore actually writes (#691).

  `KilnCMS.CMS.VersionDiff` reports what changed between two versions and
  `KilnCMS.CMS.Changes.RestoreVersion` writes one of them back. Those two lists
  were maintained independently, and they drifted: the diff reported nineteen
  fields while the restore moved seven. An editor read `Audience: public →
  members`, clicked the Restore button rendered two inches away, was told
  "Restored that version." — and the audience did not move.

  So both are derived here from the resource itself, minus two hand-maintained
  exclusion lists. A new attribute on a content type (or on a dynamic type's
  own columns) becomes diffable *and* restorable without touching this module;
  only a deliberate exclusion is written by hand.

  ## The exclusions

  `@bookkeeping` is not editorial content: tenancy, the paper-trail pointer, the
  derived search column, soft-delete. It is invisible to both sides.

  `@not_restorable` *is* editorial content and is reported by the diff, but a
  restore deliberately leaves it alone:

    * `state`, `published_at`, `scheduled_at`, `unpublish_at` — workflow. A
      restore is an edit to the document, not a publish or an unpublish; moving
      `state` here would let it bypass `AshStateMachine`'s transitions and the
      consent gate on `:publish` (#356).
    * `author_id` — attribution. Reverting the text of a document does not make
      a previous author responsible for it again.

  Anything excluded here is what `restorable?/1` answers `false` for, so the
  compare modal can mark those rows rather than leaving the editor to discover
  it after clicking.

  Identity, timestamps, the lock counter and the embedding are *not* listed in
  either exclusion — they're read off the resource at call time via the primary
  key and `AshPaperTrail`'s own `ignore_attributes`, because a snapshot cannot
  contain what PaperTrail never wrote. Restating that list by hand is how a
  newly-ignored attribute ends up reported as *removed* on every comparison
  against the working draft.
  """

  # Bookkeeping, not editorial content. Showing these would bury the one line
  # the editor actually came to read; restoring them would rewrite tenancy.
  @bookkeeping ~w(
    org_id type_definition_id published_version_id
    archived_at deleted_at search_text
  )a

  # The block tree gets its own section in the diff, keyed on stable block ids —
  # printing it again as one field row would dump a Portable Text AST beneath
  # its own rendered diff. It is very much restorable.
  @block_field :blocks

  # Reported by the diff, deliberately untouched by a restore. See the moduledoc.
  @not_restorable ~w(state published_at scheduled_at unpublish_at author_id)a

  # Editorially significant first; anything else the resource declares (a dynamic
  # type's own columns, a future attribute) is appended alphabetically rather
  # than dropped.
  @field_order ~w(
    title slug path_alias excerpt state audience locale
    seo_title seo_description seo_keywords seo_image canonical_url
    published_at scheduled_at unpublish_at
    author_id category_id featured_image_id custom_fields
  )a

  @doc """
  Every attribute of `resource` that PaperTrail records — bookkeeping included.

  The one definition of "what a version can contain": `KilnCMS.CMS.VersionSnapshot`
  builds the working-draft snapshot from it, and `content_fields/1` narrows it to
  the editorial subset. Both sides have to agree about the primary key and
  `ignore_attributes` or a comparison against the working draft reports the
  disagreement as a change.
  """
  @spec tracked_fields(module()) :: [atom()]
  def tracked_fields(resource) do
    # A snapshot can only hold what PaperTrail wrote, so what PaperTrail skips is
    # what this skips — read from the resource rather than restated here.
    untracked =
      Ash.Resource.Info.primary_key(resource) ++
        AshPaperTrail.Resource.Info.ignore_attributes(resource)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(& &1.name)
    |> Enum.reject(&(&1 in untracked))
  end

  @doc """
  Every editorial attribute of `resource` that version history covers, in
  display order — the union of `diffable_fields/1` and `restorable_fields/1`.
  """
  @spec content_fields(module()) :: [atom()]
  def content_fields(resource) do
    names = resource |> tracked_fields() |> Enum.reject(&(&1 in @bookkeeping))

    known = Enum.filter(@field_order, &(&1 in names))
    rest = names |> Enum.reject(&(&1 in @field_order)) |> Enum.sort()

    known ++ rest
  end

  @doc "The attributes `KilnCMS.CMS.VersionDiff` compares as field rows, in display order."
  @spec diffable_fields(module()) :: [atom()]
  def diffable_fields(resource) do
    Enum.reject(content_fields(resource), &(&1 == @block_field))
  end

  @doc """
  The attributes `KilnCMS.CMS.Changes.RestoreVersion` writes back, in display order.

  Includes `:blocks`, which the diff renders separately but a restore very much
  has to move.
  """
  @spec restorable_fields(module()) :: [atom()]
  def restorable_fields(resource) do
    Enum.reject(content_fields(resource), &(&1 in @not_restorable))
  end

  @doc """
  Whether restoring a version of `resource` writes `name` back.

  Defined as membership in `restorable_fields/1` rather than as its own test
  against `@not_restorable`: a second predicate is a second thing to keep in
  step, and answering `true` for a bookkeeping column or for an attribute the
  resource doesn't declare is the same silent lie #691 was filed about — the
  compare modal would leave a row unmarked that the restore never writes.
  """
  @spec restorable?(module(), atom()) :: boolean()
  def restorable?(resource, name), do: name in restorable_fields(resource)
end
