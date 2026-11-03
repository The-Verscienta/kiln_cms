defmodule KilnCMS.CMS.Validations.SynonymRule do
  @moduledoc """
  A `SearchSynonym` must say something: a `:group` names at least two
  equivalent terms, and a `:one_way` rule at least one term and one thing it
  expands to, none of which is also one of its terms. Checked after
  `Changes.NormalizeSynonymTerms`, so the counts are of distinct terms.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    terms = Ash.Changeset.get_attribute(changeset, :terms) || []
    targets = Ash.Changeset.get_attribute(changeset, :expands_to) || []

    check(Ash.Changeset.get_attribute(changeset, :kind), terms, targets)
  end

  defp check(:group, terms, _targets) when length(terms) < 2,
    do: error(:terms, "a synonym group needs at least two different terms")

  defp check(:one_way, [], _targets), do: error(:terms, "a one-way rule needs a term to match")

  defp check(:one_way, _terms, []),
    do: error(:expands_to, "a one-way rule needs something to expand to")

  defp check(:one_way, terms, targets) do
    case Enum.find(targets, &(&1 in terms)) do
      nil -> :ok
      term -> error(:expands_to, "#{inspect(term)} is already one of the rule's terms")
    end
  end

  defp check(_kind, _terms, _targets), do: :ok

  @impl true
  def describe(_opts), do: [message: "must name the terms the rule relates", vars: []]

  defp error(field, message),
    do: {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
end
