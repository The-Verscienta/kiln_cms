defmodule KilnCMS.CMS.CalendarRequeryMonitorTest do
  @moduledoc """
  The monitor is the only thing that carries `kiln_cms.calendar.requery` to an
  operator in production (#1336), so what matters is that it attaches a real
  handler and that its arithmetic distinguishes a coalescing drain from a
  defeated one.
  """
  # Not async: attaches a VM-wide `:telemetry` handler and owns a named process.
  use ExUnit.Case, async: false

  alias KilnCMS.CMS.CalendarRequeryMonitor

  @event [:kiln_cms, :calendar, :requery]

  setup do
    # The application already started one under its own name; a second would
    # collide. Drain whatever the suite has emitted so each test starts clean.
    CalendarRequeryMonitor.flush()
    :ok
  end

  defp emit(org_id, messages) do
    :telemetry.execute(@event, %{messages: messages}, %{org_id: org_id})
  end

  # `:telemetry.execute/3` runs handlers synchronously in this process, so the
  # `send/2` has happened by the time execute returns — but the monitor is a
  # separate process, so let it drain its mailbox before asserting.
  defp settle, do: CalendarRequeryMonitor.flush()

  test "a handler is actually attached to the event" do
    handlers = :telemetry.list_handlers(@event)

    assert Enum.any?(handlers, &(&1.id == "kiln-cms-calendar-requery-monitor")),
           "no monitor handler attached — the event would dispatch to nothing in " <>
             "production, which is the #678 failure this module exists to avoid"
  end

  test "a coalescing drain shows a mean well above 1" do
    org = Ash.UUID.generate()

    # One re-query answering 20 messages, twice: a burst absorbed whole.
    emit(org, 20)
    emit(org, 18)

    assert [row] = settle()
    assert row.org_id == org
    assert row.requeries == 2
    assert row.messages == 38
    assert row.mean == 19.0
    assert row.max == 20
  end

  test "a defeated drain shows many re-queries pinned at mean 1.0" do
    org = Ash.UUID.generate()

    # The #1336 signature: every re-query answered exactly one message.
    for _ <- 1..25, do: emit(org, 1)

    assert [row] = settle()
    assert row.requeries == 25
    assert row.mean == 1.0

    # The pair is what makes it evidence: a lone editorial change is also
    # mean 1.0, and must not read the same as a defeated drain.
    assert row.requeries > 1
  end

  test "orgs are tallied separately and ordered by volume" do
    busy = Ash.UUID.generate()
    quiet = Ash.UUID.generate()

    for _ <- 1..5, do: emit(busy, 1)
    emit(quiet, 3)

    rows = settle()

    assert [%{org_id: ^busy, requeries: 5}, %{org_id: ^quiet, requeries: 1}] = rows
  end

  test "a window with no re-queries reports nothing" do
    assert settle() == []
  end

  test "a malformed event is ignored rather than crashing the monitor" do
    org = Ash.UUID.generate()

    # No `messages` measurement: defaults to 1 rather than raising.
    :telemetry.execute(@event, %{}, %{org_id: org})
    # Non-integer: dropped, since a mean built from it would be meaningless.
    :telemetry.execute(@event, %{messages: :lots}, %{org_id: org})

    assert [row] = settle()
    assert row.requeries == 1

    assert Process.alive?(Process.whereis(CalendarRequeryMonitor)),
           "the monitor died on a malformed event — :telemetry would then have " <>
             "detached the handler and the signal would go quiet silently"
  end
end
