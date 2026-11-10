defmodule KilnCMS.Test.SecurityAlerts do
  @moduledoc """
  Helpers for tests of security alerts (#2245).

  Alerts are off for the suite (`config/test.exs`: a claim takes a row lock on
  its window, and sandboxed tests would wait on each other's). `enable/0` turns
  them on for one test — `Application.put_env`, so only from an
  `async: false` module — and puts the setting back when the test exits.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias KilnCMS.Repo

  @doc "Turn alerts on for the calling test. `async: false` modules only."
  @spec enable() :: :ok
  def enable do
    previous = Application.get_env(:kiln_cms, KilnCMS.Security.Alerts)
    Application.put_env(:kiln_cms, KilnCMS.Security.Alerts, enabled: true)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, KilnCMS.Security.Alerts, previous),
        else: Application.delete_env(:kiln_cms, KilnCMS.Security.Alerts)
    end)
  end

  @doc "Run the alert delivery triggers (`:deliver_alert`, `:deliver_summary`) to completion."
  @spec deliver() :: term()
  def deliver do
    AshOban.schedule_and_run_triggers(KilnCMS.Security.AlertDispatch,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )
  end

  @doc "Every dispatch row, oldest first, as string-keyed maps (raw: nobody may read them)."
  @spec dispatches() :: [map()]
  def dispatches do
    %{rows: rows, columns: columns} =
      Repo.query!("SELECT * FROM security_alert_dispatches ORDER BY inserted_at, id")

    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn
        {key, <<_::binary-size(16)>> = uuid} when key in ~w(id org_id first_event_id) ->
          {key, Ecto.UUID.load!(uuid)}

        pair ->
          pair
      end)
    end)
  end

  @doc """
  Close a dispatch's window, so its summary is due: the window becomes
  `[now - 30 min, now - 2 min)`. Events recorded during the test are newer
  than that; `backdate_events/0` moves them inside it.
  """
  @spec close_window(String.t()) :: :ok
  def close_window(id) do
    Repo.query!(
      """
      UPDATE security_alert_dispatches
      SET window_started_at = (now() AT TIME ZONE 'UTC') - interval '30 minutes',
          window_ends_at = (now() AT TIME ZONE 'UTC') - interval '2 minutes'
      WHERE id = $1::text::uuid
      """,
      [id]
    )

    :ok
  end

  @doc "Move every audit event 10 minutes back: inside a `close_window/1` window."
  @spec backdate_events() :: :ok
  def backdate_events do
    Repo.query!("UPDATE security_events SET inserted_at = inserted_at - interval '10 minutes'")
    :ok
  end
end
