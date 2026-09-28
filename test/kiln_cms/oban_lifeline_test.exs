defmodule KilnCMS.ObanLifelineTest do
  @moduledoc """
  Jobs orphaned `executing` by a shutdown are rescued (#1718).

  A node stopped mid-deploy kills whatever outlives Oban's 15 s grace period,
  and without a rescuer the row stays `executing` for ever: never retried,
  never discarded, and — for a `unique` worker — blocking every later enqueue
  of itself. `KilnCMS.Application.oban_config/0` appends `Oban.Lifeline`.

  Under `testing: :manual` Oban starts no plugins, so the plugin's work is
  driven here through the engine call it makes each tick
  (`Oban.Engine.rescue_jobs/3`), with the window the application configures.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO
  import Ecto.Query

  alias KilnCMS.Application, as: App

  defmodule StrandedWorker do
    @moduledoc false
    use Oban.Worker, queue: :default, max_attempts: 3

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  describe "the assembled Oban config" do
    test "carries the Lifeline alongside the injected crontab" do
      plugins = Keyword.fetch!(App.oban_config(), :plugins)

      assert {Oban.Lifeline, opts} = List.keyfind(plugins, Oban.Lifeline, 0)
      assert opts[:rescue_after] == App.oban_rescue_after()

      # The cron injection ran and kept its own plugin — neither injector
      # drops the other's.
      assert {Oban.Plugins.Cron, cron} = List.keyfind(plugins, Oban.Plugins.Cron, 0)

      assert {_expr, KilnCMS.Governance.CheckpointWorker} =
               List.keyfind(cron[:crontab], KilnCMS.Governance.CheckpointWorker, 1)

      assert List.keymember?(plugins, Oban.Plugins.Pruner, 0)
    end

    test "is a config Oban accepts" do
      assert :ok = Oban.Config.validate(App.oban_config())
    end

    test "defaults to three hours" do
      assert App.oban_rescue_after() == :timer.hours(3)
    end

    test "a Lifeline already configured is not doubled" do
      with_oban_plugins([{Oban.Plugins.Cron, []}, {Oban.Pro.Plugins.DynamicLifeline, []}], fn ->
        plugins = Keyword.fetch!(App.oban_config(), :plugins)

        refute List.keymember?(plugins, Oban.Lifeline, 0)
        assert List.keymember?(plugins, Oban.Pro.Plugins.DynamicLifeline, 0)
      end)
    end
  end

  describe "KILN_OBAN_RESCUE_AFTER_MINUTES" do
    test "an env-var string of minutes is honoured" do
      with_rescue_minutes(" 240 ", fn ->
        assert App.oban_rescue_after() == :timer.minutes(240)
      end)
    end

    test "false switches the rescuer off" do
      for off <- [false, "false", "off"] do
        with_rescue_minutes(off, fn ->
          assert App.oban_rescue_after() == nil
          refute List.keymember?(Keyword.fetch!(App.oban_config(), :plugins), Oban.Lifeline, 0)
        end)
      end
    end

    test "an unusable value warns and keeps the default rather than crash the boot" do
      for bad <- ["", "0", "-5", "2h", "90.5"] do
        with_rescue_minutes(bad, fn ->
          stderr =
            capture_io(:stderr, fn -> assert App.oban_rescue_after() == :timer.hours(3) end)

          assert stderr =~ "KILN_OBAN_RESCUE_AFTER_MINUTES"
        end)
      end
    end
  end

  describe "the rescue window versus the workers it guards" do
    # The rescue is time-based: a job still legitimately running when the
    # window closes is made `available` and executes a second time. So every
    # worker that bounds itself must be bounded well inside the window. A
    # worker that raises its `timeout/1` past it fails here, not in production.
    test "every worker's timeout is shorter than rescue_after, with margin" do
      rescue_after = App.oban_rescue_after()
      margin = :timer.minutes(30)

      {:ok, modules} = :application.get_key(:kiln_cms, :modules)

      timeouts =
        for module <- modules,
            Code.ensure_loaded?(module),
            function_exported?(module, :__opts__, 0),
            function_exported?(module, :timeout, 1),
            timeout = module.timeout(%Oban.Job{args: %{}}),
            is_integer(timeout),
            do: {module, timeout}

      # The ceiling the default was chosen against; if this worker loses its
      # timeout the guard above would pass vacuously.
      assert {KilnCMS.Backups.Worker, :timer.hours(2)} in timeouts

      too_long = for {module, timeout} <- timeouts, timeout + margin > rescue_after, do: module

      assert too_long == [],
             "#{inspect(too_long)} may run within 30 min of rescue_after " <>
               "(#{rescue_after} ms): raise :oban_rescue_after_minutes in config/config.exs"
    end
  end

  describe "rescuing" do
    test "an orphan past the window goes back to available" do
      job = stranded(attempt: 1, age: App.oban_rescue_after() + :timer.minutes(1))

      rescue!()

      assert %{state: "available"} = Repo.reload!(job)
    end

    test "an orphan that has spent its attempts is discarded" do
      job = stranded(attempt: 3, age: App.oban_rescue_after() + :timer.minutes(1))

      rescue!()

      assert %{state: "discarded", discarded_at: %DateTime{}} = Repo.reload!(job)
    end

    test "a job still inside the window is left running" do
      job = stranded(attempt: 1, age: App.oban_rescue_after() - :timer.minutes(10))

      rescue!()

      assert %{state: "executing"} = Repo.reload!(job)
    end

    test "a rescued unique job no longer blocks its own re-enqueue for ever" do
      # StaticExportWorker is `unique` across incomplete states: an orphaned
      # `executing` row makes every later insert a conflict. Rescued, the row
      # is runnable again, so the work it stands for actually happens.
      {:ok, job} = Oban.insert(KilnCMS.Firing.StaticExportWorker.new(%{}))
      strand!(job, attempt: 1, age: App.oban_rescue_after() + :timer.minutes(1))

      rescue!()

      assert %{state: "available"} = Repo.reload!(job)
    end
  end

  defp stranded(opts) do
    {:ok, job} = Oban.insert(StrandedWorker.new(%{}))
    strand!(job, opts)
  end

  # What a node killed mid-job leaves behind: `executing`, stamped when it
  # started, never acked.
  defp strand!(job, opts) do
    attempted_at = DateTime.add(DateTime.utc_now(), -opts[:age], :millisecond)

    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: "executing", attempt: opts[:attempt], attempted_at: attempted_at]
      )

    Repo.reload!(job)
  end

  # The call `Oban.Lifeline` makes on each tick, with the configured window.
  defp rescue!,
    do: Oban.Engine.rescue_jobs(Oban.config(), Oban.Job, rescue_after: App.oban_rescue_after())

  defp with_rescue_minutes(value, fun) do
    with_env(:oban_rescue_after_minutes, value, fun)
  end

  defp with_oban_plugins(plugins, fun) do
    oban = Application.fetch_env!(:kiln_cms, Oban)
    with_env(Oban, Keyword.put(oban, :plugins, plugins), fun)
  end

  defp with_env(key, value, fun) do
    previous = Application.fetch_env(:kiln_cms, key)
    Application.put_env(:kiln_cms, key, value)

    try do
      fun.()
    after
      case previous do
        {:ok, old} -> Application.put_env(:kiln_cms, key, old)
        :error -> Application.delete_env(:kiln_cms, key)
      end
    end
  end
end
