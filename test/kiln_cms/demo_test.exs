defmodule KilnCMS.DemoTest do
  @moduledoc """
  Demo mode's operator surface (`docs/demo-mode.md`): hard off by default,
  refusing on a database that isn't a demo's, and the schedule the banner
  reads. The restore itself is `KilnCMS.Demo.RestoreTest`; the refusals in
  isolation are `KilnCMS.Demo.GuardTest`.
  """
  use KilnCMS.DataCase, async: false
  @moduletag :capture_log

  alias KilnCMS.Demo
  alias KilnCMS.Demo.ResetWorker

  setup do
    saved = [
      {KilnCMS.Demo, Application.get_env(:kiln_cms, KilnCMS.Demo)},
      {:demo_reset_cron, Application.get_env(:kiln_cms, :demo_reset_cron)},
      {:environment, Application.get_env(:kiln_cms, :environment)}
    ]

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:kiln_cms, key)
        {key, value} -> Application.put_env(:kiln_cms, key, value)
      end)
    end)

    :ok
  end

  defp demo(opts), do: Application.put_env(:kiln_cms, KilnCMS.Demo, opts)
  defp schedule(cron), do: Application.put_env(:kiln_cms, :demo_reset_cron, cron)

  @disabled "Demo mode is off. Set KILN_DEMO_RESET=confirm on the demo deployment (only `confirm` enables it)."

  describe "hard off by default" do
    test "nothing configured means off" do
      Application.delete_env(:kiln_cms, KilnCMS.Demo)

      assert Demo.enabled?() == false
      assert Demo.reset() == {:error, :disabled}
    end

    test "a truthy value that isn't `true` does not switch it on" do
      demo(enabled: "true")

      assert Demo.enabled?() == false
    end

    test "reset!/1 raises the explanation rather than returning it" do
      demo(enabled: false)

      assert_raise RuntimeError, @disabled, fn -> Demo.reset!(shell: fn _ -> :ok end) end
    end

    test "capturing a snapshot is refused the same way" do
      demo(enabled: false)

      assert_raise RuntimeError, @disabled, fn -> Demo.capture_golden!(shell: fn _ -> :ok end) end
    end
  end

  describe "enabled, on a database that isn't a demo's" do
    test "the test database is refused by name, with no override" do
      demo(enabled: true)
      {_host, database} = KilnCMS.Repo.target()

      assert Demo.reset() == {:error, {:database_not_demo, database}}

      assert Demo.explain({:database_not_demo, database}) ==
               "Refusing to reset #{inspect(database)}: a demo database's name must contain \"demo\". " <>
                 "This check has no override."
    end

    test "the scheduled job cancels — retrying would change nothing" do
      demo(enabled: true)
      {_host, database} = KilnCMS.Repo.target()

      assert ResetWorker.perform(%Oban.Job{id: 42, args: %{}}) ==
               {:cancel, Demo.explain({:database_not_demo, database})}
    end

    test "the job cancels with the reason when demo mode is off" do
      demo(enabled: false)

      assert ResetWorker.perform(%Oban.Job{id: 42, args: %{}}) == {:cancel, @disabled}
    end
  end

  describe "next_reset_at/1" do
    test "is the schedule's next tick" do
      demo(enabled: true)
      schedule("0 * * * *")

      assert Demo.next_reset_at(~U[2026-09-11 10:15:30Z]) == ~U[2026-09-11 11:00:00Z]
    end

    test "follows any cron the operator sets" do
      demo(enabled: true)
      schedule(" */15 * * * * ")

      assert Demo.schedule() == "*/15 * * * *"
      assert Demo.next_reset_at(~U[2026-09-11 10:15:30Z]) == ~U[2026-09-11 10:30:00Z]
    end

    test "is nil with demo mode off, whatever the schedule says" do
      demo(enabled: false)
      schedule("0 * * * *")

      assert Demo.next_reset_at(~U[2026-09-11 10:15:30Z]) == nil
    end

    test "is nil for a switched-off or unplaceable schedule" do
      demo(enabled: true)

      for cron <- ["false", "@reboot", "not a cron"] do
        schedule(cron)
        assert Demo.next_reset_at(~U[2026-09-11 10:15:30Z]) == nil
      end

      Application.delete_env(:kiln_cms, :demo_reset_cron)
      assert Demo.next_reset_at(~U[2026-09-11 10:15:30Z]) == nil
    end
  end

  describe "golden_path/0" do
    test "defaults under BACKUP_DIR, beside the backups" do
      demo(enabled: true)

      assert Demo.golden_path() == Path.join([KilnCMS.Backups.dir(), "demo", "golden.dump"])
      assert Demo.dir() == Path.join(KilnCMS.Backups.dir(), "demo")
    end

    test "KILN_DEMO_GOLDEN_PATH overrides it" do
      demo(enabled: true, golden_path: "/data/demo/golden.dump")

      assert Demo.golden_path() == "/data/demo/golden.dump"
      assert Demo.dir() == "/data/demo"
    end
  end

  describe "refusal?/1" do
    test "a check that stopped the reset before it began is a refusal" do
      for reason <- [
            :disabled,
            {:database_not_demo, "kiln_prod"},
            {:golden_missing, "/x"},
            {:golden_not_demo, "kiln_prod"},
            {:missing_tool, "psql"}
          ] do
        assert Demo.refusal?(reason) == true
      end
    end

    test "a reset that tried and failed is not" do
      for reason <- [{:restore_failed, "x"}, {:migrate_failed, "x"}, {:dump_failed, "x"}] do
        assert Demo.refusal?(reason) == false
      end
    end
  end

  describe "the environment label" do
    test "a demo is labelled `demo` without KILN_ENV_LABEL" do
      demo(enabled: true)
      Application.put_env(:kiln_cms, :environment, label: nil)

      assert KilnCMS.Environment.label() == "demo"
    end

    test "KILN_ENV_LABEL still wins" do
      demo(enabled: true)
      Application.put_env(:kiln_cms, :environment, label: "try-kiln")

      assert KilnCMS.Environment.label() == "try-kiln"
    end

    test "outside demo mode an unlabelled deployment stays unlabelled" do
      demo(enabled: false)
      Application.put_env(:kiln_cms, :environment, label: nil)

      assert KilnCMS.Environment.label() == nil
    end
  end
end
