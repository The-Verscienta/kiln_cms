defmodule KilnCMS.Security.Changes.ReportAlertFailed do
  @moduledoc """
  Says that a security alert was given up on (#2642): `:mark_failed`, which
  the delivery triggers run once a dispatch has used its ten attempts, logs
  at `:error` and emits `[:kiln_cms, :security, :alert_failed]` with
  `%{count: 1}`, so a stuck delivery shows on a dashboard rather than only as
  a `failed_at` stamp nobody reads.

  The metadata has the keys a claim failure has
  (`KilnCMS.Security.AlertGate`): `scope`, `kind` and `reason`, here always
  `:delivery_exhausted`. Plus `phase`: `:alert` when the alert itself was
  never sent, `:summary` when it was and its window's summary was not.

  From `after_transaction/2` on a committed stamp only, so a stamp that rolls
  back is not counted, and once per dispatch: the trigger never picks a
  stamped row up again.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, dispatch} = result ->
        report(dispatch)
        result

      _changeset, result ->
        result
    end)
  end

  defp report(dispatch) do
    phase = if dispatch.alert_sent_at, do: :summary, else: :alert

    Logger.error(
      "Security alert #{dispatch.id} (#{dispatch.kind}, #{phase}) was not delivered " <>
        "after its last attempt; it is stamped failed and will not be retried."
    )

    :telemetry.execute([:kiln_cms, :security, :alert_failed], %{count: 1}, %{
      scope: dispatch.scope,
      kind: to_string(dispatch.kind),
      reason: :delivery_exhausted,
      phase: phase
    })
  end
end
