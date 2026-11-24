defmodule KilnCMS.Billing.Changes.RefuseBilledComp do
  @moduledoc """
  Refuses a comp over a membership the provider may still bill (#3156).

  The decision is made by `Membership.:comp`'s `upsert_condition`, inside the
  `ON CONFLICT ... DO UPDATE ... WHERE`: a row that is `:active`, `:past_due`
  or `:incomplete` and holds a provider subscription id is left untouched, and
  the action hands it back flagged `upsert_skipped`. This change turns that
  flag into `KilnCMS.Billing.Errors.StillBilled`, so the caller sees a refusal
  rather than a row that looks comped and is not.

  In an `after_action` declared before `KilnCMS.Billing.Changes.RecordTransition`,
  so a refused comp short-circuits before any trail row, recompute or webhook,
  and the error rolls the action's transaction back.
  """
  use Ash.Resource.Change

  alias KilnCMS.Billing.Errors.StillBilled

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, membership ->
      if Ash.Resource.get_metadata(membership, :upsert_skipped),
        do: {:error, StillBilled.exception(field: :status)},
        else: {:ok, membership}
    end)
  end
end
