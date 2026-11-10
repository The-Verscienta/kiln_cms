defmodule KilnCMS.Security.AlertGate do
  @moduledoc """
  The debounce in front of security alerts (#2245): one
  `KilnCMS.Security.AlertDispatch` row per scope, kind and alert window, and
  one per notice.

  ## One statement, and why it is raw SQL

  `claim/6` is a single `INSERT ... ON CONFLICT (scope, kind, window_index) DO
  NOTHING RETURNING id`, the same shape as `KilnCMS.Accounts.ThrottleStore.hit/5`
  and for the same reason: the window index comes from the **database's**
  clock (`floor(epoch_ms / window_ms)`, with the window length a parameter), so
  two nodes whose clocks disagree still claim the same row. The first event of
  a kind in a window gets `{:ok, id}`; every later one gets `:exists` and is
  left for the window's summary to count. No row is ever updated here.

  ## Inside the emitter's transaction

  A claim is made in the transaction of the audit event that raised it, so a
  rolled-back emitter leaves no alert behind. A claim outside a transaction is
  a bug, and is treated as a failed claim.

  Nothing is enqueued here: the dispatch's AshOban trigger finds the row within
  a minute. An `Oban.insert` inside the emitter's transaction would be one more
  write that can fail it.

  ## A failed claim never fails the emitter — unless it must

  A claim waits at most two seconds for a row lock (`SET LOCAL lock_timeout`,
  restored after): a concurrent claim of the same window holds one until its
  transaction ends.

    * `mode: :best_effort` (the default) runs the insert under a savepoint. A
      failure rolls back to it, is logged at `:error` and counted on
      `[:kiln_cms, :security, :alert_failed]`, and `{:error, reason}` is
      returned; the emitter's own write goes on and commits. Losing one alert
      is better than losing the role grant or the audit event that raised it.
    * `mode: :required` runs without a savepoint and raises: the caller's
      transaction is aborted. For an alert that has a fallback outside the
      transaction (a reused API key mails its legacy alert when the event
      cannot be recorded).

  `insert_notice!/2` is always required: an `alerts_silenced` notice that
  cannot be written rolls back the change that silenced the alerts.
  """

  require Logger

  alias KilnCMS.Repo
  alias KilnCMS.Security.Alerts

  # Bounds how long a claim waits on a concurrent claim's row lock.
  @lock_timeout "2s"

  # A row lives a day past its window, which is as long as the triggers look.
  @keep_ms :timer.hours(24)

  @prune_batch 10_000
  @prune_max_batches 100

  @claim_sql """
  INSERT INTO security_alert_dispatches AS d
    (id, scope, kind, channel, org_id, window_index, window_started_at, window_ends_at,
     first_event_id, threshold_count, notice, expires_at, inserted_at)
  SELECT gen_random_uuid(), $1::text, $2::text, $3::text, $4::text::uuid, w.idx,
         to_timestamp((w.idx * $5::bigint)::float8 / 1000) AT TIME ZONE 'UTC',
         to_timestamp(((w.idx + 1) * $5::bigint)::float8 / 1000) AT TIME ZONE 'UTC',
         $6::text::uuid, $7::bigint, '{}'::jsonb,
         to_timestamp((((w.idx + 1) * $5::bigint) + $9::bigint)::float8 / 1000) AT TIME ZONE 'UTC',
         clock_timestamp() AT TIME ZONE 'UTC'
  FROM (SELECT coalesce($8::bigint,
                        floor(extract(epoch FROM clock_timestamp()) * 1000 / $5::bigint)::bigint)
               AS idx) AS w
  ON CONFLICT (scope, kind, window_index) DO NOTHING
  RETURNING d.id::text
  """

  @notice_sql """
  INSERT INTO security_alert_dispatches
    (id, scope, kind, channel, org_id, window_index, window_started_at, window_ends_at,
     notice, expires_at, inserted_at)
  SELECT w.id, 'notice:' || w.id::text, 'alerts_silenced', 'notice', $1::text::uuid, 0,
         w.now, w.now, $2::jsonb, w.now + ($3::bigint * interval '1 millisecond'), w.now
  FROM (SELECT gen_random_uuid() AS id, clock_timestamp() AT TIME ZONE 'UTC' AS now) AS w
  RETURNING id::text
  """

  @notice_keys ~w(change kinds endpoint_id actor_id)

  @typedoc "Where a claim is made from: `:site`, `:platform` or `:notice`."
  @type channel :: :site | :platform | :notice

  @doc """
  Claim the alert window for `kind` in `scope` (an org id or `"platform"`),
  in the caller's transaction. `org_id` is the site the alert is about;
  `event_id` the audit event raising it.

  Returns `{:ok, dispatch_id}` for the first claim of the window, `:exists`
  when it was already claimed, or — in `:best_effort` mode — `{:error, reason}`
  when the claim could not be made (see the moduledoc).

  Options:

    * `:mode` — `:best_effort` (default) or `:required`.
    * `:window_index` — claim this window rather than the current one: the
      failed-sign-in tally's, so the alert and the tally agree on the window.
    * `:threshold_count` — the count that crossed the threshold.
    * `:window_ms` — the window length (default `Alerts.window_ms/0`).
  """
  @spec claim(
          String.t(),
          atom() | String.t(),
          channel(),
          Ash.UUID.t(),
          Ash.UUID.t() | nil,
          keyword()
        ) :: {:ok, Ash.UUID.t()} | :exists | {:error, term()}
  def claim(scope, kind, channel, org_id, event_id, opts \\ [])
      when is_binary(scope) and channel in [:site, :platform] do
    mode = Keyword.get(opts, :mode, :best_effort)
    window_ms = Keyword.get(opts, :window_ms, Alerts.window_ms())

    params = [
      scope,
      to_string(kind),
      Atom.to_string(channel),
      org_id,
      window_ms,
      event_id,
      Keyword.get(opts, :threshold_count),
      Keyword.get(opts, :window_index),
      @keep_ms
    ]

    result =
      if Repo.in_transaction?() do
        with_lock_timeout(fn -> insert(params, mode) end)
      else
        {:error, :not_in_transaction}
      end

    case result do
      {:ok, %{rows: [[id]]}} -> {:ok, id}
      {:ok, %{rows: []}} -> :exists
      {:error, reason} -> failed(mode, scope, kind, reason)
    end
  end

  defp insert(params, :best_effort), do: Repo.query(@claim_sql, params, mode: :savepoint)

  defp insert(params, :required) do
    {:ok, Repo.query!(@claim_sql, params)}
  end

  # `SET LOCAL` would hold until the transaction ends, so the previous value is
  # read and put back: the emitter's own statements keep the timeout they had.
  defp with_lock_timeout(fun) do
    %{rows: [[previous]]} = Repo.query!("SELECT current_setting('lock_timeout')")
    Repo.query!("SELECT set_config('lock_timeout', $1, true)", [@lock_timeout])

    try do
      fun.()
    after
      restore_lock_timeout(previous)
    end
  end

  defp restore_lock_timeout(previous) do
    Repo.query("SELECT set_config('lock_timeout', $1, true)", [previous], mode: :savepoint)
  rescue
    # A required claim that failed has aborted the transaction, which is
    # about to roll back and take the setting with it.
    _aborted -> :ok
  end

  defp failed(:required, scope, kind, reason) do
    raise "security alert claim failed (#{scope} #{kind}): #{describe(reason)}"
  end

  defp failed(:best_effort, scope, kind, reason) do
    Logger.error(
      "Security alert #{kind} for #{scope} could not be claimed and will not be sent: " <>
        describe(reason)
    )

    :telemetry.execute([:kiln_cms, :security, :alert_failed], %{count: 1}, %{
      scope: scope,
      kind: to_string(kind),
      reason: reason
    })

    {:error, reason}
  end

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(reason), do: inspect(reason)

  @doc """
  Write an `alerts_silenced` notice for `org_id`, in the caller's transaction,
  and return its dispatch id. `notice` holds the `change` (one of
  `KilnCMS.Security.Alerts.notice_changes/0`) and, where they apply, the
  `kinds` turned off, the webhook `endpoint_id` and the `actor_id`; any other
  key is dropped.

  **Fails closed**: raises on any failure, so the change that would have gone
  unannounced rolls back with it.
  """
  @spec insert_notice!(Ash.UUID.t(), map()) :: Ash.UUID.t()
  def insert_notice!(org_id, %{} = notice) when is_binary(org_id) do
    notice = notice |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.take(@notice_keys)

    unless notice["change"] in Alerts.notice_changes() do
      raise ArgumentError, "unknown alerts_silenced change: #{inspect(notice["change"])}"
    end

    %{rows: [[id]]} = Repo.query!(@notice_sql, [org_id, notice, @keep_ms])
    id
  end

  @doc """
  Deletes every dispatch past its `expires_at`, in bounded batches. Returns how
  many went. Run by `AlertDispatch`'s scheduled `:prune`.
  """
  @spec prune() :: non_neg_integer()
  def prune, do: prune(0, 0)

  defp prune(deleted, batches) when batches >= @prune_max_batches, do: deleted

  defp prune(deleted, batches) do
    %{num_rows: n} =
      Repo.query!(
        """
        DELETE FROM security_alert_dispatches WHERE id = ANY(ARRAY(
          SELECT id FROM security_alert_dispatches
          WHERE expires_at < (clock_timestamp() AT TIME ZONE 'UTC') LIMIT $1
        ))
        """,
        [@prune_batch]
      )

    if n < @prune_batch, do: deleted + n, else: prune(deleted + n, batches + 1)
  end
end
