defmodule KilnCMS.Experiments.Changes.RequireVariants do
  @moduledoc """
  Refuses to start an experiment that cannot produce a result (#499).

  Three things have to hold before traffic is split, and none of them is
  recoverable once visitors are in the experiment:

    * **at least two variants** — one arm is not a test;
    * **exactly one control**, so results have a baseline and "the control won"
      is expressible;
    * **weights that sum above zero** — otherwise `Assignment.choose_bucket/3`
      has no arm to return, and the page renders canonically while the results
      table reports an experiment in flight;
    * **no other running experiment on the same document**, because two
      overlapping patches make every measurement uninterpretable — you cannot
      tell which change moved the number.

  Checked at `:start` rather than on the resource, because a `draft` is
  deliberately allowed to be half-built while an editor works on it.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      variants = load_variants(changeset, context)

      cond do
        length(variants) < 2 ->
          Ash.Changeset.add_error(changeset,
            field: :variants,
            message: "an experiment needs at least two variants to be a test"
          )

        Enum.sum_by(variants, & &1.weight) <= 0 ->
          Ash.Changeset.add_error(changeset,
            field: :variants,
            message:
              "an experiment whose weights sum to zero serves no arm at all; " <>
                "give at least one variant a weight above zero"
          )

        Enum.count(variants, & &1.control) != 1 ->
          Ash.Changeset.add_error(changeset,
            field: :variants,
            message: "an experiment needs exactly one control variant"
          )

        already_running?(changeset, context) ->
          Ash.Changeset.add_error(changeset,
            field: :document_id,
            message:
              "another experiment is already running on this document; " <>
                "two overlapping patches make both results uninterpretable"
          )

        true ->
          changeset
      end
    end)
  end

  defp load_variants(changeset, context) do
    KilnCMS.Experiments.list_variants!(
      query: [filter: [experiment_id: changeset.data.id]],
      authorize?: false,
      tenant: context.tenant
    )
  end

  defp already_running?(changeset, context) do
    KilnCMS.Experiments.running_experiments!(authorize?: false, tenant: context.tenant)
    |> Enum.any?(&(&1.document_id == changeset.data.document_id and &1.id != changeset.data.id))
  end
end
