defmodule KilnCMS.CMS.Changes.TrackAliasDerivation do
  @moduledoc """
  Records whether a written `path_alias` was derived or written by a person
  (#1890), on every create and update of a content type.

  Kiln used to answer "may a regeneration rewrite this alias?" by re-deriving
  it and comparing. That fails once a derivation's inputs change for reasons
  unrelated to the record: after a content-tree move (#1597) a stale derived
  `[ancestors]` path and a hand-written one both differ from the new
  derivation, and nothing tells them apart. A recorded fact does not drift.

  The rule, applied after every other change has run (a `before_action`, so it
  sees the final attributes):

    * `Changes.DeriveAlias` filled the alias and set `path_alias_derived` to
      `true` itself: left alone;
    * the alias is being written with `context: %{path_alias_derived: true}`,
      which only `KilnCMS.CMS.SlugRegeneration` passes when it writes the
      pattern's own expansion: `true`;
    * the alias is being cleared: `nil`, since there is nothing to describe;
    * any other write of the alias — the editor, the working copy, an import,
      a version restore, the API: `false`, a person's value.

  An unchanged alias leaves the flag as it was. A write that repeats the stored
  value is no change to Ash, so re-saving a form does not pin a derived alias.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # Always a hook, never decided here: `Changes.DeriveAlias` is an action
    # change and may not have run yet, so only the final changeset knows.
    Ash.Changeset.before_action(changeset, &record/1)
  end

  # An atomic update that does not write the alias needs nothing from this
  # change; one that does has to run the hook.
  @impl true
  def atomic(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :path_alias),
      do: {:not_atomic, "path_alias is written: its derivation is recorded in a hook"},
      else: :ok
  end

  defp record(changeset) do
    cond do
      not Ash.Changeset.changing_attribute?(changeset, :path_alias) ->
        changeset

      Ash.Changeset.changing_attribute?(changeset, :path_alias_derived) ->
        changeset

      Ash.Changeset.get_attribute(changeset, :path_alias) in [nil, ""] ->
        Ash.Changeset.force_change_attribute(changeset, :path_alias_derived, nil)

      changeset.context[:path_alias_derived] == true ->
        Ash.Changeset.force_change_attribute(changeset, :path_alias_derived, true)

      true ->
        Ash.Changeset.force_change_attribute(changeset, :path_alias_derived, false)
    end
  end
end
