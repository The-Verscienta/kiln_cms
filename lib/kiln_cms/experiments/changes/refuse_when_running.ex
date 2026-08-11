defmodule KilnCMS.Experiments.Changes.RefuseWhenRunning do
  @moduledoc """
  Refuses to add, edit or remove a variant once its experiment is running (#499).

  The weights and the patches **are** the experiment, so all three verbs matter,
  not just edits:

    * adding an arm to a running 50/50 changes the weight total from 2 to 3,
      which re-buckets every keyed visitor onto a different variant while the
      counters keep climbing;
    * removing one orphans its `VariantDay` rows — there is no foreign key on
      `variant_id` — so the totals survive with nothing to attribute them to;
    * rebalancing 50/50 to 90/10 on day three makes every count gathered before
      the change incomparable with every count after it.

  None of these announces itself. The counters are integers that keep going up
  either way, and nobody finds out until they read a result that was never
  measuring one thing.

  A `before_action` change rather than a validation: this needs a database read,
  and a validation runs at changeset **build** time — which, once phase 2's
  variant form exists, means one query per keystroke through
  `AshPhoenix.Form.validate`. It also fails **closed**: a variant whose parent
  cannot be read is not editable, because "I could not check" is not "it is
  fine".
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case experiment_state(changeset, context) do
        :draft ->
          changeset

        {:unreadable, id} ->
          Ash.Changeset.add_error(changeset,
            field: :experiment_id,
            message: "could not read experiment #{id} to check whether it is running"
          )

        state ->
          Ash.Changeset.add_error(changeset,
            field: :experiment_id,
            message:
              "cannot change the variants of a #{state} experiment — the split is the " <>
                "experiment, and editing it makes every count gathered so far unreadable"
          )
      end
    end)
  end

  defp experiment_state(changeset, context) do
    id =
      Ash.Changeset.get_attribute(changeset, :experiment_id) ||
        Map.get(changeset.data, :experiment_id)

    case KilnCMS.Experiments.get_experiment(id, authorize?: false, tenant: context.tenant) do
      {:ok, %{state: state}} -> state
      _other -> {:unreadable, id}
    end
  end
end
