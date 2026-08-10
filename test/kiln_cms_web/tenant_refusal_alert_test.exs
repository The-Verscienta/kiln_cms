defmodule KilnCMSWeb.TenantRefusalAlertTest do
  @moduledoc """
  The aggregated tenant-refusal-flood alert (#678), tested against the module
  directly — the call-site tests in `KilnCMSWeb.TenantStrictHostTest` cover
  that each real refusal reaches it and with the right `source`.

  `async: false`: the cooldown bucket is process-global ETS, same reason
  `KilnCMS.Mail.RelayAlertTest` runs in isolation.
  """
  use ExUnit.Case, async: false

  alias KilnCMSWeb.TenantRefusalAlert

  setup do
    TenantRefusalAlert.reset()

    ref = make_ref()
    handler_id = "tenant-refusal-alert-#{inspect(ref)}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:kiln_cms, :tenant, :refusal_flood],
      fn _event, measurements, metadata, _cfg ->
        send(test_pid, {ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{ref: ref}
  end

  @tag :capture_log
  test "notify/2 fires once for a source, with that source and the host", %{ref: ref} do
    assert :ok = TenantRefusalAlert.notify(:plug, "evil.example.com")

    assert_receive {^ref, %{count: 1}, %{source: :plug}}
  end

  @tag :capture_log
  test "cooldown suppresses a second refusal on the SAME source", %{ref: ref} do
    assert :ok = TenantRefusalAlert.notify(:live, "one.example.com")
    assert_receive {^ref, _measurements, %{source: :live}}

    assert :ok = TenantRefusalAlert.notify(:live, "two.example.com")
    refute_receive {^ref, _measurements, %{source: :live}}
  end

  @tag :capture_log
  test "each source has its own independent cooldown bucket", %{ref: ref} do
    assert :ok = TenantRefusalAlert.notify(:gql, "a.example.com")
    assert_receive {^ref, _measurements, %{source: :gql}}

    # :bridge has never fired, so it is not swallowed by :gql's cooldown — the
    # whole point of tagging: an operator can tell which surface is flooded.
    assert :ok = TenantRefusalAlert.notify(:bridge, "b.example.com")
    assert_receive {^ref, _measurements, %{source: :bridge}}

    assert :ok = TenantRefusalAlert.notify(:collab, "c.example.com")
    assert_receive {^ref, _measurements, %{source: :collab}}
  end

  test "an unknown source is rejected rather than silently accepted" do
    # Via apply/3 so the compiler's static type check (source is one of the 5
    # tagged atoms) doesn't itself flag this call — the point is the runtime
    # guard on notify/2, not a type the compiler would catch anyway.
    assert_raise FunctionClauseError, fn ->
      apply(TenantRefusalAlert, :notify, [:carrier_pigeon, nil])
    end
  end
end
