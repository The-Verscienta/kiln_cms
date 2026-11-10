defmodule KilnCMS.Security.AlertGateTest do
  @moduledoc """
  `KilnCMS.Security.AlertGate` (#2245) inside the sandbox: one claim per scope,
  kind and window by the database clock, a failed claim that leaves the
  emitter's transaction alive (or, when required, takes it down), notices that
  fail closed, and the prune. Concurrency is `AlertGateRaceTest`, below.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts
  alias KilnCMS.Repo
  alias KilnCMS.Security
  alias KilnCMS.Security.AlertGate
  alias KilnCMS.Test.BudgetWindow

  defp scope, do: "test-#{System.unique_integer([:positive])}"
  defp org_id, do: Accounts.default_org_id()

  defp in_txn(fun) do
    {:ok, result} = Repo.transaction(fun)
    result
  end

  defp row(id) do
    %{rows: [row], columns: columns} =
      Repo.query!(
        "SELECT * FROM security_alert_dispatches WHERE id = $1::text::uuid",
        [id]
      )

    columns |> Enum.zip(row) |> Map.new()
  end

  defp count(scope) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM security_alert_dispatches WHERE scope = $1", [scope])

    n
  end

  defp attach_failures do
    test = self()
    ref = make_ref()

    :telemetry.attach(
      "alert-gate-#{inspect(ref)}",
      [:kiln_cms, :security, :alert_failed],
      fn _event, measurements, metadata, _ ->
        send(test, {:alert_failed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("alert-gate-#{inspect(ref)}") end)
  end

  describe "claim/6" do
    test "one claim per scope, kind and window; the rest find it taken" do
      s = scope()
      window = BudgetWindow.fresh_window_ms()
      event_id = Ecto.UUID.generate()

      results =
        in_txn(fn ->
          for _ <- 1..3,
              do: AlertGate.claim(s, :lockout, :site, org_id(), event_id, window_ms: window)
        end)

      assert [{:ok, id}, :exists, :exists] = results
      assert count(s) == 1

      row = row(id)
      assert row["kind"] == "lockout"
      assert row["channel"] == "site"
      assert Ecto.UUID.cast!(row["org_id"]) == org_id()
      assert Ecto.UUID.cast!(row["first_event_id"]) == event_id
      assert row["notice"] == %{}
      assert row["alert_sent_at"] == nil
    end

    test "another kind, another scope and the next window each claim their own" do
      s = scope()
      w0 = BudgetWindow.fresh_window_ms(0)
      w1 = BudgetWindow.fresh_window_ms(1)

      results =
        in_txn(fn ->
          [
            AlertGate.claim(s, :lockout, :site, org_id(), nil, window_ms: w0),
            AlertGate.claim(s, :new_admin, :site, org_id(), nil, window_ms: w0),
            AlertGate.claim(s <> "-b", :lockout, :site, org_id(), nil, window_ms: w0),
            AlertGate.claim(s, :lockout, :site, org_id(), nil, window_ms: w1)
          ]
        end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
    end

    test "the window comes from the database clock, and its bounds and expiry follow" do
      s = scope()
      window = :timer.minutes(15)

      {:ok, id} =
        in_txn(fn -> AlertGate.claim(s, :lockout, :site, org_id(), nil, window_ms: window) end)

      %{rows: [[db_index]]} =
        Repo.query!(
          "SELECT floor(extract(epoch FROM clock_timestamp()) * 1000 / $1::bigint)::bigint",
          [window]
        )

      row = row(id)
      assert row["window_index"] == db_index

      assert DateTime.to_unix(
               DateTime.from_naive!(row["window_started_at"], "Etc/UTC"),
               :millisecond
             ) ==
               db_index * window

      assert NaiveDateTime.diff(row["window_ends_at"], row["window_started_at"], :millisecond) ==
               window

      assert NaiveDateTime.diff(row["expires_at"], row["window_ends_at"], :hour) == 24
    end

    test "a given window index and threshold count are stored as given" do
      s = scope()

      {:ok, id} =
        in_txn(fn ->
          AlertGate.claim(s, :failed_sign_ins, :site, org_id(), nil,
            window_index: 42,
            threshold_count: 10,
            window_ms: 1_000
          )
        end)

      row = row(id)
      assert row["window_index"] == 42
      assert row["threshold_count"] == 10
      assert NaiveDateTime.to_iso8601(row["window_started_at"]) =~ "1970-01-01T00:00:42"
    end

    test "the caller's lock_timeout is put back" do
      setting =
        in_txn(fn ->
          Repo.query!("SET LOCAL lock_timeout = '7s'")
          {:ok, _} = AlertGate.claim(scope(), :lockout, :site, org_id(), nil)
          %{rows: [[value]]} = Repo.query!("SELECT current_setting('lock_timeout')")
          value
        end)

      assert setting == "7s"
    end
  end

  describe "a failed claim" do
    test "outside a transaction is a failure, logged and counted" do
      attach_failures()
      s = scope()

      log =
        capture_log(fn ->
          assert {:error, :not_in_transaction} =
                   AlertGate.claim(s, :lockout, :site, org_id(), nil)
        end)

      assert log =~ "could not be claimed"
      assert_received {:alert_failed, %{count: 1}, %{scope: ^s, kind: "lockout"}}
      assert count(s) == 0
    end

    test "inside a transaction leaves the emitter's own writes to commit" do
      attach_failures()

      {{event, result}, log} = with_log(fn -> in_txn(&record_then_fail_claim/0) end)
      assert log =~ "could not be claimed"

      assert {:error, %Postgrex.Error{}} = result
      assert_received {:alert_failed, %{count: 1}, %{kind: "lockout"}}

      # The audit event written before the failed claim committed.
      assert {:ok, _} =
               Security.get_event(event.id,
                 tenant: org_id(),
                 actor: %Accounts.User{id: Ecto.UUID.generate(), role: :admin}
               )
    end

    test "a required claim raises, and the emitter's transaction rolls back" do
      s = scope()
      user_id = Ecto.UUID.generate()

      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Security.record!(%{type: :sign_in_locked, target_id: user_id},
            actor: Security.system(),
            tenant: org_id()
          )

          AlertGate.claim(s, :lockout, :site, "not-a-uuid", nil, mode: :required)
        end)
      end

      # authorize?: false — reading the log back in a test.
      assert Security.list_events!(tenant: org_id(), authorize?: false)
             |> Enum.filter(&(&1.target_id == user_id)) == []

      assert_raise RuntimeError, ~r/not_in_transaction/, fn ->
        AlertGate.claim(s, :lockout, :site, org_id(), nil, mode: :required)
      end

      assert count(s) == 0
    end
  end

  # An audit event, then a claim whose SQL fails (an org id that is no uuid).
  defp record_then_fail_claim do
    event =
      Security.record!(%{type: :sign_in_locked}, actor: Security.system(), tenant: org_id())

    {event, AlertGate.claim(scope(), :lockout, :site, "not-a-uuid", event.id)}
  end

  describe "insert_notice!/2" do
    test "writes a notice of its own, keeping only the notice keys" do
      actor_id = Ecto.UUID.generate()

      id =
        in_txn(fn ->
          AlertGate.insert_notice!(org_id(), %{
            change: "kind_disabled",
            kinds: ["lockout"],
            actor_id: actor_id,
            url: "https://hooks.example.com/secret"
          })
        end)

      row = row(id)
      assert row["scope"] == "notice:" <> id
      assert row["kind"] == "alerts_silenced"
      assert row["channel"] == "notice"
      assert row["window_index"] == 0

      assert row["notice"] == %{
               "change" => "kind_disabled",
               "kinds" => ["lockout"],
               "actor_id" => actor_id
             }
    end

    test "two notices are two rows" do
      a = in_txn(fn -> AlertGate.insert_notice!(org_id(), %{change: "admin_removed"}) end)
      b = in_txn(fn -> AlertGate.insert_notice!(org_id(), %{change: "admin_removed"}) end)
      assert a != b
    end

    test "an unknown change is refused" do
      assert_raise ArgumentError, ~r/unknown alerts_silenced change/, fn ->
        AlertGate.insert_notice!(org_id(), %{change: "made_up"})
      end
    end

    test "fails closed: a notice that cannot be written rolls back the change it announces" do
      admin = %Accounts.User{id: Ecto.UUID.generate(), role: :admin}

      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          # Its cache bust is an after-transaction hook; inside this outer
          # transaction that is the point of the test, not a mistake.
          KilnCMS.CMS.save_site_security_alerts!(%{disabled_kinds: ["lockout"]},
            actor: admin,
            tenant: org_id(),
            context: %{warn_on_transaction_hooks?: false}
          )

          AlertGate.insert_notice!("not-a-uuid", %{change: "kind_disabled"})
        end)
      end

      assert KilnCMS.Security.Alerts.settings_for(org_id()).disabled_kinds == ["failed_sign_ins"]
    end
  end

  describe "prune and authorization" do
    test "prune deletes rows past their expiry and keeps the rest" do
      old = scope()
      fresh = scope()

      in_txn(fn ->
        {:ok, _} = AlertGate.claim(old, :lockout, :site, org_id(), nil)
        {:ok, _} = AlertGate.claim(fresh, :lockout, :site, org_id(), nil)
      end)

      Repo.query!(
        "UPDATE security_alert_dispatches SET expires_at = expires_at - interval '3 days' WHERE scope = $1",
        [old]
      )

      assert AlertGate.prune() >= 1
      assert count(old) == 0
      assert count(fresh) == 1
    end

    test "nobody reads a row, and the prune is the operator's" do
      s = scope()
      in_txn(fn -> {:ok, _} = AlertGate.claim(s, :lockout, :site, org_id(), nil) end)

      admin = %Accounts.User{id: Ecto.UUID.generate(), role: :admin}
      assert {:ok, []} = Security.list_alert_dispatches(actor: admin)
      assert {:ok, []} = Security.list_alert_dispatches(actor: Security.alerts_system())

      assert {:error, %Ash.Error.Forbidden{}} = Security.prune_alert_dispatches(actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Security.prune_alert_dispatches(actor: Security.alerts_system())

      assert is_integer(
               Security.prune_alert_dispatches!(actor: KilnCMS.SystemActor.new(:operator))
             )
    end
  end
end

defmodule KilnCMS.Security.AlertGateRaceTest do
  @moduledoc """
  `AlertGate.claim/6` under concurrency (#2245). The sandbox runs a test on one
  connection where nothing ever waits, so these run **outside** it
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`), on real connections whose
  transactions commit or roll back; each test's rows are deleted on exit.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Repo
  alias KilnCMS.Security.AlertGate

  @moduletag :capture_log

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    scope = "race-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn ->
        Repo.query!("DELETE FROM security_alert_dispatches WHERE scope = $1", [scope])
      end)
    end)

    %{scope: scope, org_id: unboxed(&KilnCMS.Accounts.default_org_id/0)}
  end

  defp count(scope) do
    unboxed(fn ->
      %{rows: [[n]]} =
        Repo.query!("SELECT count(*) FROM security_alert_dispatches WHERE scope = $1", [scope])

      n
    end)
  end

  # `fun` in a real transaction of its own, in a task.
  defp in_task_txn(fun), do: Task.async(fn -> unboxed(fn -> Repo.transaction(fun) end) end)

  # A claim held open until the test says how to end it.
  defp holder(scope, org_id) do
    test = self()

    in_task_txn(fn ->
      result = AlertGate.claim(scope, :lockout, :site, org_id, nil)
      send(test, {:claimed, result})

      receive do
        :commit -> result
        :rollback -> Repo.rollback(:asked)
      end
    end)
  end

  defp contender(scope, org_id),
    do: in_task_txn(fn -> AlertGate.claim(scope, :lockout, :site, org_id, nil) end)

  test "a claim waits on one in flight, and finds it taken when that commits", ctx do
    a = holder(ctx.scope, ctx.org_id)
    assert_receive {:claimed, {:ok, _}}, 2_000

    b = contender(ctx.scope, ctx.org_id)
    assert Task.yield(b, 300) == nil

    send(a.pid, :commit)
    assert {:ok, {:ok, _}} = Task.await(a)
    assert {:ok, :exists} = Task.await(b)
    assert count(ctx.scope) == 1
  end

  test "a claim in flight that rolls back leaves the window to the next", ctx do
    a = holder(ctx.scope, ctx.org_id)
    assert_receive {:claimed, {:ok, _}}, 2_000

    b = contender(ctx.scope, ctx.org_id)
    assert Task.yield(b, 300) == nil

    send(a.pid, :rollback)
    assert {:error, :asked} = Task.await(a)
    assert {:ok, {:ok, _}} = Task.await(b)
    assert count(ctx.scope) == 1
  end

  test "a burst of thirty claims one row", ctx do
    results =
      1..30
      |> Enum.map(fn _ -> contender(ctx.scope, ctx.org_id) end)
      |> Task.await_many(15_000)

    assert Enum.count(results, &match?({:ok, {:ok, _}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:ok, :exists})) == 29
    assert count(ctx.scope) == 1
  end

  test "a claim stuck behind a held lock gives up after the lock timeout, and the emitter commits",
       ctx do
    a = holder(ctx.scope, ctx.org_id)
    assert_receive {:claimed, {:ok, _}}, 2_000

    b =
      in_task_txn(fn ->
        result = AlertGate.claim(ctx.scope, :lockout, :site, ctx.org_id, nil)
        # The transaction is still usable after the failed claim.
        %{rows: [[1]]} = Repo.query!("SELECT 1")
        result
      end)

    assert {:ok, {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}}} =
             Task.await(b, 10_000)

    send(a.pid, :commit)
    Task.await(a)
    assert count(ctx.scope) == 1
  end
end
