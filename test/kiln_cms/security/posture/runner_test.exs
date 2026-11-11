defmodule KilnCMS.Security.Posture.RunnerTest do
  @moduledoc """
  `KilnCMS.Security.Posture.Runner` (#2252): a check that raises, throws,
  exits, answers nonsense or overruns is an error row (never a pass) and
  leaves the others alone; the deadline holds when the caller is gone; a full
  supervisor is "busy"; and the reader's locale reaches the check.

  `async: false`: the busy case fills the posture task supervisor, which is
  node-wide.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import KilnCMS.PostureFixtures, only: [context: 2]

  alias Kiln.Security.Check.Result
  alias KilnCMS.Security.Posture
  alias KilnCMS.Security.Posture.Entry
  alias KilnCMS.Security.Posture.Runner

  defmodule Passing do
    use Kiln.Security.Check
    def id, do: "test.passing"
    def title, do: "Passing"
    def scope, do: :site
    def run(_context), do: pass("Fine.", facts: %{n: 1}, fix_path: "https://evil.example")
  end

  defmodule Raising do
    use Kiln.Security.Check
    def id, do: "test.raising"
    def title, do: "Raising"
    def scope, do: :site
    def run(_context), do: raise("secret detail from the plugin")
  end

  defmodule Throwing do
    use Kiln.Security.Check
    def id, do: "test.throwing"
    def title, do: "Throwing"
    def scope, do: :site
    def run(_context), do: throw(:nope)
  end

  defmodule Exiting do
    use Kiln.Security.Check
    def id, do: "test.exiting"
    def title, do: "Exiting"
    def scope, do: :site
    def run(_context), do: exit(:gone)
  end

  defmodule Invalid do
    use Kiln.Security.Check
    def id, do: "test.invalid"
    def title, do: "Invalid"
    def scope, do: :site
    def run(_context), do: {:ok, :looks_fine}
  end

  defmodule Unsanitizable do
    use Kiln.Security.Check
    def id, do: "test.unsanitizable"
    def title, do: "Unsanitizable"
    def scope, do: :site

    # An improper list of details makes the sanitizer itself raise.
    def run(_context), do: %Result{status: :pass, summary: "ok", details: ["a" | :b]}
  end

  defmodule Hanging do
    use Kiln.Security.Check
    def id, do: "test.hanging"
    def title, do: "Hanging"
    def scope, do: :site
    def timeout, do: 150

    def run(%{locale: "<" <> _ = test_pid}) do
      # The test pid is smuggled in as a string: the context's locale.
      send(:erlang.list_to_pid(String.to_charlist(test_pid)), {:hanging, self()})
      Process.sleep(:infinity)
    end

    def run(_context), do: Process.sleep(:infinity)
  end

  defmodule Localized do
    use Kiln.Security.Check
    def id, do: "test.localized"
    def title, do: "Localized"
    def scope, do: :site
    def run(_context), do: pass(Gettext.get_locale(KilnCMSWeb.Gettext))
  end

  defp descriptor(module, overrides \\ %{}) do
    {:ok, described} = Kiln.Security.Check.describe(module)

    described
    |> Map.merge(%{source: :config, timeout: Posture.Registry.clamp(described.timeout)})
    |> Map.merge(overrides)
  end

  defp run(modules, opts \\ []) do
    ctx = context(nil, opts)
    Runner.run(Enum.map(modules, &descriptor/1), fn _scope -> ctx end)
  end

  test "a passing check is sanitized and kept" do
    assert [%Entry{status: :pass, error: nil, result: %Result{} = result}] = run([Passing])
    assert result.facts == %{"n" => 1}
    assert result.fix_path == nil
  end

  test "raise, throw and exit are each a crashed row, and the others still run" do
    log =
      capture_log(fn ->
        entries = run([Raising, Passing, Throwing, Exiting])

        assert Enum.map(entries, &{&1.id, &1.status, &1.error}) == [
                 {"test.raising", :error, :crashed},
                 {"test.passing", :pass, nil},
                 {"test.throwing", :error, :crashed},
                 {"test.exiting", :error, :crashed}
               ]

        # The page gets the reason class, never the exception.
        refute Enum.any?(entries, &(&1.result && &1.result.summary =~ "secret"))
      end)

    assert log =~ "test.raising"
    assert log =~ "secret detail from the plugin"
  end

  test "an answer that is not a result is an invalid-result row" do
    assert [%Entry{status: :error, error: :invalid_result, result: nil}] = run([Invalid])
  end

  test "a result the sanitizer raises on is an invalid-result row, and the others still run" do
    log =
      capture_log(fn ->
        assert [
                 %Entry{status: :error, error: :invalid_result, result: nil},
                 %Entry{status: :pass}
               ] = run([Unsanitizable, Passing])
      end)

    assert log =~ "test.unsanitizable"
  end

  test "a check past its deadline is killed and is a timeout row, without holding the rest" do
    started = System.monotonic_time(:millisecond)
    entries = run([Hanging, Passing])
    elapsed = System.monotonic_time(:millisecond) - started

    assert [%Entry{status: :error, error: :timeout}, %Entry{status: :pass}] = entries
    # The slowest deadline bounds the wall time.
    assert elapsed < 150 + 400
  end

  test "the deadline holds when the caller dies first" do
    test_pid = self() |> :erlang.pid_to_list() |> to_string()
    ctx = context(nil, locale: test_pid)

    caller = spawn(fn -> Runner.run([descriptor(Hanging)], fn _scope -> ctx end) end)
    assert_receive {:hanging, task}, 1000

    ref = Process.monitor(task)
    Process.exit(caller, :kill)

    # Nobody is left to shut the task down; its own timer does.
    assert_receive {:DOWN, ^ref, :process, ^task, :killed}, 1000
    refute task in Task.Supervisor.children(Runner.supervisor())
  end

  test "a full supervisor is a busy row, not a crash" do
    # Fill it to `max_children`, whatever is already running there.
    blockers =
      Stream.repeatedly(fn ->
        Task.Supervisor.start_child(Runner.supervisor(), fn -> Process.sleep(:infinity) end)
      end)
      |> Enum.take_while(&match?({:ok, _pid}, &1))
      |> Enum.map(fn {:ok, pid} -> pid end)

    on_exit(fn ->
      for pid <- blockers, do: Task.Supervisor.terminate_child(Runner.supervisor(), pid)
    end)

    assert [%Entry{status: :error, error: :busy}] = run([Passing])
  end

  test "the reader's locale reaches the check" do
    assert [%Entry{result: %Result{summary: "fr"}}] = run([Localized], locale: "fr")
  end

  test "reports each check to telemetry" do
    ref = make_ref()
    test = self()

    :telemetry.attach_many(
      "posture-runner-test-#{inspect(ref)}",
      [
        [:kiln_cms, :security_posture, :check, :stop],
        [:kiln_cms, :security_posture, :check, :exception]
      ],
      fn event, measurements, metadata, _ -> send(test, {ref, event, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("posture-runner-test-#{inspect(ref)}") end)

    capture_log(fn -> run([Passing, Raising]) end)

    assert_receive {^ref, [:kiln_cms, :security_posture, :check, :stop], %{duration: _},
                    %{id: "test.passing", status: :pass}}

    assert_receive {^ref, [:kiln_cms, :security_posture, :check, :exception], _,
                    %{id: "test.raising", kind: :error}}

    assert_receive {^ref, [:kiln_cms, :security_posture, :check, :stop], _,
                    %{id: "test.raising", status: :error, error: :crashed}}
  end

  describe "the report's verdict" do
    defp entry(status),
      do: %Entry{id: "x", title: "x", scope: :site, source: :core, status: status}

    test "is the worst line, with unknown and error counted as a warning" do
      assert Posture.overall([entry(:pass), entry(:fail), entry(:warn)]) == :fail
      assert Posture.overall([entry(:pass), entry(:unknown)]) == :warn
      assert Posture.overall([entry(:pass), entry(:error)]) == :warn
      assert Posture.overall([entry(:pass), entry(:n_a)]) == :pass
      assert Posture.overall([entry(:n_a)]) == :pass
      assert Posture.overall([]) == :pass
    end

    test "counts every status" do
      assert Posture.counts([entry(:pass), entry(:pass), entry(:error)]) == %{
               fail: 0,
               warn: 0,
               error: 1,
               unknown: 0,
               pass: 2,
               n_a: 0
             }
    end

    test "sorts what to fix first, first" do
      sorted = Posture.sorted(Enum.map([:n_a, :pass, :unknown, :error, :warn, :fail], &entry/1))
      assert Enum.map(sorted, & &1.status) == [:fail, :warn, :error, :unknown, :pass, :n_a]
    end
  end
end
