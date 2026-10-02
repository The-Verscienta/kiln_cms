defmodule KilnCMS.Experiments.Validations.WinnerIsAVariant do
  @moduledoc """
  Refuses to conclude an experiment with a winner that is not one of its arms
  (#499).

  `:conclude` takes `winner_variant_id` as a `:uuid` argument and writes it
  straight to the attribute. Until this check existed the type was the **only**
  gate: a non-uuid string was refused, and any well-formed uuid was accepted and
  stored — one belonging to no variant at all, or to a variant of a *different
  experiment on the same site*.

  ## Why a loose winner is worth refusing at the action

  Nothing downstream mis-reads the id — `Promotion.winner/2` answers
  `:winner_missing` and refuses, so no wrong copy is written into a document.
  The cost is the row, and the row is **unrecoverable**:

    * `winner_variant_id` is `writable? false`, so only `:conclude` can set it;
    * the state machine has no `concluded → concluded` transition, so it cannot
      be concluded again with the right arm;
    * `:update` refuses anything but a `draft`.

  So the three ways to correct a mistake are all shut, and nothing short of SQL
  can take the bad id back out.

  What it leaves behind contradicts itself on screen. The Promote button renders
  on `state == :concluded and winner_variant_id`, so it is offered — and can
  never succeed, because the winner resolves to nothing. `winner?/2` matches no
  row at the same time, so the results table shows no `winner` badge. The page
  says both "there is a winner to promote" and "no arm won", and the only way
  out is to archive the experiment.

  It also escapes. `Changes.NotifyConcluded` puts `winner_variant_id` in the
  `experiment.concluded` payload, through the funnel that webhook endpoints,
  automation rules and ActivityPub federation share — so a dangling id reaches
  consumers outside Kiln, where nothing can tell it from a real one.

  ## Both callers already intend this; the action was the hole

  `mix kiln.experiment conclude NAME --winner VARIANT_NAME` resolves the name
  among `experiment.variants` and raises on one that is not there, and the
  editor's `<select>` is built from `@experiment.variants`. Neither can
  ordinarily produce a loose id — and the editor's options cannot even go stale,
  because `Changes.RefuseWhenRunning` freezes the arms for the whole time the
  conclude form is on screen, so no option in that list can be deleted between
  render and submit.

  What is left is a crafted LiveView event from an org admin, and — the reason
  this belongs on the action rather than in either caller — any other caller of
  the `conclude_experiment/3` code interface, which is the documented way for a
  plugin or a later surface to conclude one.

  ## Shape

  A validation, not a `before_action` change, even though it reads the database:
  `RefuseWhenRunning` is a change precisely because a variant form runs
  `AshPhoenix.Form.validate` per keystroke, and `:conclude` has no form — it is
  one `phx-submit` that calls the code interface once. The error reports through
  `field: :winner_variant_id` so it lands on the control that chose it.

  Fails **closed**, like every other read behind an experiment guard (#1659): a
  variants read that cannot be answered refuses the conclusion, because "I could
  not check" is not "it is fine".
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, context) do
    # The ARGUMENT, not the attribute: validations run before the changes, so
    # `set_attribute(:winner_variant_id, arg(:winner_variant_id))` has not
    # happened yet. `nil` is a real choice — "no winner, just stop" — and the
    # common outcome for a test that found no difference.
    case Ash.Changeset.get_argument(changeset, :winner_variant_id) do
      nil -> :ok
      id -> belongs_to_experiment(changeset, id, context)
    end
  end

  defp belongs_to_experiment(changeset, id, context) do
    # As the system (#1659), whoever is concluding: the guard must see the arms
    # to decide, and an editor's own grant is not what is being tested here.
    # `authorize_with: :error` so a refused read is an error rather than the
    # `[]` a filter policy would answer — which would read as "not an arm of
    # this experiment" and refuse a perfectly good winner.
    read =
      KilnCMS.Experiments.list_variants(
        query: [filter: [experiment_id: changeset.data.id, id: id]],
        actor: KilnCMS.Experiments.system(),
        authorize_with: :error,
        tenant: context.tenant
      )

    case read do
      {:ok, [_variant]} ->
        :ok

      {:ok, []} ->
        {:error,
         field: :winner_variant_id,
         message:
           "#{id} is not a variant of this experiment. The winner has to be one of " <>
             "its own arms — a uuid that is not cannot be promoted, cannot be " <>
             "corrected once recorded, and ships in the experiment.concluded event"}

      _unreadable ->
        {:error,
         field: :winner_variant_id,
         message: "could not read this experiment's variants to check the winner #{id}"}
    end
  end
end
