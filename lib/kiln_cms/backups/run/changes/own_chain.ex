defmodule KilnCMS.Backups.Run.Changes.OwnChain do
  @moduledoc """
  Fences the chain's Run writes (`record_progress`, `finish`, `fail`) to the
  writer's own chain (#2538): the UPDATE's WHERE requires the row's `chain_id`
  to still be the one on the struct the writer loaded.

  The status filter alone isn't enough. A step that outlived its Cancel, on a
  node that missed the signal, holds a struct of the run under its old chain;
  once a resume flips the row back to `running` under a new chain, that
  filter would admit the old step's writes. This one refuses them with an
  `Ash.Error.Changes.StaleRecord` error, the Run-level twin of the lock's
  lease check (`KilnCMS.Backups.Chain.while_holding/2`).

  Every legitimate writer already holds its own chain's struct: the recorder
  takes it from the row it opened or re-opened, and the stale-run sweep
  (`KilnCMS.Backups.reconcile_stale_runs/1`) reads the row fresh, so a sweep
  that races a resume is refused rather than failing the resumed run.

  A struct whose `chain_id` is nil (a run from before #2218) requires a nil
  `chain_id`: a nil pin in `==` would not mean "is null".
  """
  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.data.chain_id do
      nil -> Ash.Changeset.filter(changeset, Ash.Expr.expr(is_nil(chain_id)))
      id -> Ash.Changeset.filter(changeset, Ash.Expr.expr(chain_id == ^id))
    end
  end
end
