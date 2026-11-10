defmodule KilnCMS.Security.Changes.RaiseAlert do
  @moduledoc """
  Raises the security alerts (#2245) an audit event is worth, as it is
  recorded: the last change on `KilnCMS.Security.Event`'s `:record`, after
  `SanitizeMetadata`, so `KilnCMS.Security.Alerts.classify/2` reads the
  metadata the log keeps.

  An `after_action` hook, in the event's own transaction — which is the
  emitter's when the event is recorded inside one (`Recorder.record/2`), and
  the create's own otherwise (`Recorder.record_after_commit/2`). Either way a
  rolled-back event leaves no alert behind, and no alert is claimed for an
  event that was never written.

    * An **alert** is a `KilnCMS.Security.AlertGate.claim/6`: a site alert in
      the event's org (`scope` the org id), a platform alert in `"platform"`
      with the default org as its `org_id` (where its bell rows go). A failed
      claim is logged and the event commits anyway (`mode: :best_effort`),
      unless the recording context says `security_alert_required: true`: then
      it raises and the event is not written, for a caller with a fallback
      outside the transaction (`KilnCMS.Accounts.ApiKeyReuse`).
    * A **notice** (`alerts_silenced`, derived from the event) is
      `AlertGate.insert_notice!/2`, which fails closed: the event, and the
      emitter's write with it, rolls back rather than silence the alerts
      unannounced.

  When one event raises several, they are claimed in a fixed order (scope,
  then kind), so two transactions claiming the same pair of windows take
  their row locks in the same order and cannot deadlock.

  The failed-sign-in threshold arrives in the context as
  `security_alert: {:threshold, window_index, count}`; the claim takes the
  tally's window rather than the current one, so the alert and the count
  agree on which window they are about.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts
  alias KilnCMS.Security.AlertGate
  alias KilnCMS.Security.Alerts

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, event ->
      raise_alerts(event, changeset.context || %{})
      {:ok, event}
    end)
  end

  @doc false
  # The alerts and notices `event` raises, in the order they are written.
  # `Alerts.enabled?/0` (the test suite's seam) gates the window claims only:
  # a notice takes no row lock, so it is written whatever the seam says.
  @spec raise_alerts(map(), map()) :: :ok
  def raise_alerts(event, context) do
    {notices, alerts} =
      event
      |> Alerts.classify(context)
      |> Enum.split_with(&match?({_kind, :notice, _change}, &1))

    alerts = if Alerts.enabled?(), do: alerts, else: []

    alerts
    |> Enum.map(fn {kind, channel} -> {scope(channel, event), kind, channel} end)
    |> Enum.uniq()
    |> Enum.sort_by(fn {scope, kind, _channel} -> {scope, Atom.to_string(kind)} end)
    |> Enum.each(&claim(&1, event, context))

    Enum.each(notices, fn {_kind, :notice, change} ->
      AlertGate.insert_notice!(event.org_id, %{change: change, actor_id: event.actor_id})
    end)

    :ok
  end

  defp scope(:site, event), do: event.org_id
  defp scope(:platform, _event), do: "platform"

  defp claim({scope, kind, channel}, event, context) do
    org_id = if channel == :platform, do: Accounts.default_org_id(), else: event.org_id

    AlertGate.claim(scope, kind, channel, org_id, event.id, claim_opts(kind, context))
  end

  defp claim_opts(kind, context) do
    mode =
      if Map.get(context, :security_alert_required) == true, do: :required, else: :best_effort

    case {kind, Map.get(context, :security_alert)} do
      {:failed_sign_ins, {:threshold, window_index, count}} ->
        [mode: mode, window_index: window_index, threshold_count: count]

      _other ->
        [mode: mode]
    end
  end
end
