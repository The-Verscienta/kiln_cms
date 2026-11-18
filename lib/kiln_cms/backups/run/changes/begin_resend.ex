defmodule KilnCMS.Backups.Run.Changes.BeginResend do
  @moduledoc """
  The guard and bookkeeping of `KilnCMS.Backups.Run`'s `:begin_resend` action
  (#2949): a re-send's first step moves the run to its chain.

  The loaded run must still be one `KilnCMS.Backups.Resend.eligible/2`
  accepts, else an error on `status`. The UPDATE's WHERE is pinned to the run
  as the re-send read it: an in-app, `succeeded` row whose `updated_at` is
  the loaded struct's. The re-send's setup reads the run, checks its lease,
  then begins with that struct at once (critic change 1), so a Cancel of the
  re-send that commits in between (`Run`'s `:cancel_resend`, which writes the
  row) makes this match nothing: the setup gets a `StaleRecord` error and
  stops quietly. So does anything else that wrote the run meanwhile.

  On success it appends a `resend` log line. The status, `finished_at` and
  `error` are never touched.
  """
  use Ash.Resource.Change

  require Ash.Expr

  alias KilnCMS.Backups.Resend

  @impl true
  def change(changeset, _opts, _context) do
    run = changeset.data

    case Resend.eligible(run) do
      :ok ->
        entry = %{
          at: DateTime.utc_now(),
          level: :info,
          step: "resend",
          message: "Re-sending this backup to the off-site destinations it missed"
        }

        loaded_at = run.updated_at

        changeset
        |> Ash.Changeset.force_change_attribute(:log, (run.log || []) ++ [entry])
        |> Ash.Changeset.filter(
          Ash.Expr.expr(origin == :app and status == :succeeded and updated_at == ^loaded_at)
        )

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "can't be re-sent: %{reason}",
          vars: [reason: inspect(reason)]
        )
    end
  end
end
