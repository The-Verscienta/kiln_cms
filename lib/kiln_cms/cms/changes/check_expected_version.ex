defmodule KilnCMS.CMS.Changes.CheckExpectedVersion do
  @moduledoc """
  Opt-in optimistic concurrency for stateless (headless) writers.

  The built-in `optimistic_lock(:lock_version)` compares against the record the
  changeset was built from. A LiveView editor holds that record across the
  session, so the check protects it — but a stateless JSON:API / bridge PATCH
  loads the row fresh on every request, so its in-memory `lock_version` always
  equals the DB and the lock never fires. Such a writer therefore silently
  clobbers a concurrent editor's save (audit T3.3).

  When a client passes the `:expected_version` argument (the public
  `lock_version` it read before editing), this rejects the update if the record
  has moved on since — the ETag-style conflict signal a headless client needs.
  Omitting the argument preserves the previous last-writer-wins behavior, so
  existing clients are unaffected.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :expected_version) do
      nil ->
        changeset

      expected ->
        if expected == changeset.data.lock_version do
          changeset
        else
          Ash.Changeset.add_error(changeset,
            field: :expected_version,
            message:
              "stale version — the content changed since you read it (expected #{expected}, now #{changeset.data.lock_version})"
          )
        end
    end
  end
end
