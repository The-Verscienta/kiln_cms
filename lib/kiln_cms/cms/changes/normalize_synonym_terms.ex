defmodule KilnCMS.CMS.Changes.NormalizeSynonymTerms do
  @moduledoc """
  Stores a `SearchSynonym`'s `terms` and `expands_to` the way
  `KilnCMS.Search.Synonyms` compares them: trimmed, lowercased, inner
  whitespace collapsed, blanks and repeats dropped. The console then shows
  the rule as it will match, and `Validations.SynonymRule` counts the terms
  that are really there — `["Reishi", " reishi "]` is one term, not a group.

  A group carries no `expands_to`: switching a one-way rule to a group drops
  the old targets rather than keeping a list nothing reads.
  """
  use Ash.Resource.Change

  alias KilnCMS.Search.Synonyms

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> normalize(:terms)
    |> normalize(:expands_to)
    |> drop_group_targets()
  end

  defp normalize(changeset, field) do
    if Ash.Changeset.changing_attribute?(changeset, field) do
      terms =
        changeset
        |> Ash.Changeset.get_attribute(field)
        |> List.wrap()
        |> Enum.map(&Synonyms.normalize/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      Ash.Changeset.force_change_attribute(changeset, field, terms)
    else
      changeset
    end
  end

  defp drop_group_targets(changeset) do
    if Ash.Changeset.get_attribute(changeset, :kind) == :group and
         Ash.Changeset.get_attribute(changeset, :expands_to) not in [nil, []] do
      Ash.Changeset.force_change_attribute(changeset, :expands_to, [])
    else
      changeset
    end
  end
end
