defmodule KilnCMS.Security.RetentionTest do
  @moduledoc """
  The security log retention setting and its daily prune worker (#2241): the
  per-org window (default 365, 0 = forever), who may change it, and that the
  worker prunes per org, only past the window, and is scheduled.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Security
  alias KilnCMS.Security.Event
  alias KilnCMS.Security.PruneWorker

  @moduletag :capture_log

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ret-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp seed_at(org_id, days_ago) do
    Ash.Seed.seed!(Event, %{
      org_id: org_id,
      type: :sign_in,
      inserted_at: DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)
    })
  end

  defp count(org_id),
    do: Event |> Ash.read!(authorize?: false, tenant: org_id) |> length()

  describe "retention_days/1 and set_retention_days/2" do
    test "defaults to 365 with no row" do
      assert Security.retention_days(org("ret-default").id) == 365
    end

    test "an admin sets it, per org" do
      a = org("ret-a")
      b = org("ret-b")
      admin = user(:admin)

      assert {:ok, _} = Security.set_retention_days(30, actor: admin, tenant: a.id)
      assert {:ok, _} = Security.set_retention_days(0, actor: admin, tenant: a.id)
      assert Security.retention_days(a.id) == 0
      assert Security.retention_days(b.id) == 365

      assert {:ok, _} = Security.set_retention_days(90, actor: admin, tenant: a.id)
      assert Security.retention_days(a.id) == 90
    end

    test "refused for an editor, a viewer and anonymous; the value is unchanged" do
      o = org("ret-refused")

      for actor <- [user(:editor), user(:viewer), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Security.set_retention_days(1, actor: actor, tenant: o.id)
      end

      assert Security.retention_days(o.id) == 365
    end

    test "rejects negative, non-integer and absurd values" do
      o = org("ret-invalid")
      admin = user(:admin)

      for bad <- [-1, "abc", 1.5, KilnCMS.CMS.SiteSecurityLog.max_days() + 1] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Security.set_retention_days(bad, actor: admin, tenant: o.id)
      end
    end

    test "an unreadable setting keeps everything (fails closed to 0)" do
      o = org("ret-closed")
      Security.set_retention_days(10, actor: user(:admin), tenant: o.id)

      assert KilnCMS.OrgSettings.with_actor(nil, fn -> Security.retention_days(o.id) end) == 0
    end
  end

  describe "PruneWorker" do
    test "prunes each org to its own window, only past it, and honours 0" do
      short = org("ret-short")
      forever = org("ret-forever")
      default = org("ret-default-window")
      admin = user(:admin)

      {:ok, _} = Security.set_retention_days(30, actor: admin, tenant: short.id)
      {:ok, _} = Security.set_retention_days(0, actor: admin, tenant: forever.id)

      for o <- [short, forever, default] do
        seed_at(o.id, 400)
        seed_at(o.id, 100)
        seed_at(o.id, 5)
      end

      assert :ok = Oban.Testing.perform_job(PruneWorker, %{}, repo: KilnCMS.Repo)

      # 30 days: only the 5-day row survives. 0: nothing is deleted.
      # No row: 365 days, so only the 400-day row goes. Changing the window is
      # itself audited (`org_setting_changed`), a fresh event that survives too.
      assert count(short.id) == 1 + 1
      assert count(forever.id) == 3 + 1
      assert count(default.id) == 2
    end

    test "fails loudly when the prune grant is gone" do
      o = org("ret-grant")
      seed_at(o.id, 400)

      # Every log is attempted (#2541), then the job raises naming the failed
      # ones, the instance log among them.
      error =
        assert_raise RuntimeError, fn ->
          Security.with_actor(nil, fn -> PruneWorker.perform(%Oban.Job{}) end)
        end

      assert error.message =~ "security log prune failed"
      assert error.message =~ ":instance"
      assert error.message =~ o.id
      assert count(o.id) == 1
    end

    test "is registered on the crontab" do
      cron = Keyword.fetch!(KilnCMS.Application.oban_config(), :plugins)
      assert {Oban.Plugins.Cron, opts} = List.keyfind(cron, Oban.Plugins.Cron, 0)
      assert List.keymember?(opts[:crontab], PruneWorker, 1)
    end
  end
end
