defmodule KilnCMSWeb.TenantStrictHostAutoTest do
  @moduledoc """
  An unset `TENANT_STRICT_HOST` is **auto** (#1547): strict host matching is on
  if and only if more than one organization exists. An explicit `true` still
  wins; an explicit `false` only while there is one organization (#1662).

  The per-request answer comes from `KilnCMSWeb.Tenant.OrgCount`'s cached
  verdict, not from a count, so these tests are mostly about that verdict: that
  it is right at boot, that it moves the moment the second organization is
  created (no restart), that it reaches other nodes — or, when the broadcast is
  missed, is caught by a recount within 30 seconds (#1654) — that it never
  moves back down, and which way it fails when nobody could count.

  `async: false` — `:tenant_strict_host` is application env and the verdict is
  a `:persistent_term`; both are VM-global. Each test restores both.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures

  alias KilnCMS.Accounts
  alias KilnCMSWeb.Tenant
  alias KilnCMSWeb.Tenant.OrgCount

  setup do
    strict = Application.get_env(:kiln_cms, :tenant_strict_host)
    multi = Application.get_env(:kiln_cms, :multitenancy_enabled)
    tracking = Application.get_env(:kiln_cms, :tenant_org_tracking)
    verdict = OrgCount.verdict()

    on_exit(fn ->
      Application.put_env(:kiln_cms, :tenant_strict_host, strict)
      Application.put_env(:kiln_cms, :multitenancy_enabled, multi)
      Application.put_env(:kiln_cms, :tenant_org_tracking, tracking)
      OrgCount.put(verdict)
    end)

    Application.put_env(:kiln_cms, :multitenancy_enabled, true)
    # `config/test.exs` turns the verdict's own tracking off for the run (see
    # there); these tests are about that tracking, so it is on here.
    Application.put_env(:kiln_cms, :tenant_org_tracking, true)
    # Start every test from "nobody has counted", so a verdict another test
    # left behind cannot be what a test observes.
    OrgCount.put(:unknown)
    :ok
  end

  defp setting!(value), do: Application.put_env(:kiln_cms, :tenant_strict_host, value)

  defp unknown_host,
    do: "no-such-org-#{System.unique_integer([:positive])}.#{Tenant.base_host()}"

  # Through the action — `Ash.Seed` (the `org/1` fixture) bypasses the change
  # that keeps the verdict current, which is what a boot-time count is for.
  defp create_org(slug) do
    Accounts.create_organization(
      %{name: "Org #{slug}", slug: "#{slug}-#{System.unique_integer([:positive])}"},
      authorize?: false
    )
  end

  describe "the setting" do
    test "unset, and any non-boolean, is auto" do
      Application.delete_env(:kiln_cms, :tenant_strict_host)
      assert Tenant.strict_host_setting() == :auto

      setting!(:auto)
      assert Tenant.strict_host_setting() == :auto

      setting!(:yes)
      assert Tenant.strict_host_setting() == :auto
    end

    test "the shipped default is auto" do
      # config/test.exs pins `false` for the suite (see there); the shipped
      # default is what config/config.exs says, and that is what #1547 changed.
      assert File.read!("config/config.exs") =~
               "config :kiln_cms, :tenant_strict_host, :auto"
    end

    test "true and false mean what they say" do
      setting!(true)
      assert Tenant.strict_host_setting() == true

      setting!(false)
      assert Tenant.strict_host_setting() == false
    end
  end

  describe "auto with a single organization" do
    setup do
      setting!(:auto)
      assert OrgCount.refresh() == 1, "another test leaked an org through the action"
      :ok
    end

    test "is lenient: an unknown host is served the default org" do
      assert OrgCount.verdict() == :single
      refute Tenant.strict_host?()

      assert {:ok, org} = Tenant.fetch_org(unknown_host())
      assert org.id == Accounts.default_org_id()
    end

    test "the plug serves an unknown Host", %{conn: conn} do
      conn = %{conn | host: unknown_host()} |> get(~p"/")
      assert conn.status == 200
    end
  end

  describe "auto with two organizations" do
    setup do: setting!(:auto)

    test "is strict when the second one existed at boot" do
      org("auto-boot")

      assert OrgCount.refresh() == 2
      assert OrgCount.verdict() == :multi
      assert Tenant.strict_host?()
      assert :error = Tenant.fetch_org(unknown_host())
    end

    test "turns strict right after the second org's create, with no restart", %{conn: conn} do
      assert OrgCount.refresh() == 1
      refute Tenant.strict_host?()

      assert {:ok, _second} = create_org("auto-create")

      assert OrgCount.verdict() == :multi
      assert Tenant.strict_host?()
      assert :error = Tenant.fetch_org(unknown_host())

      conn = %{conn | host: unknown_host()} |> get(~p"/")
      assert conn.status == 404
      assert conn.halted
    end

    test "the canonical host is still served" do
      org("auto-apex")
      OrgCount.refresh()

      assert {:ok, org} = Tenant.fetch_org(Tenant.base_host())
      assert org.id == Accounts.default_org_id()
    end

    # Auto closes the gap itself, so the #660 warnings — which describe the gap
    # — have nothing to say.
    #
    # From `:single`, as on a running node: the verdict must move before the
    # warning asks it, which is the order the two changes are declared in.
    test "raises no gap warning and reports no gap" do
      assert OrgCount.refresh() == 1

      log = capture_log(fn -> assert {:ok, _} = create_org("auto-quiet") end)

      refute log =~ "TENANT_STRICT_HOST"
      refute Tenant.strict_host_gap?()
    end
  end

  describe "an explicit setting" do
    # #1662: `false` is no longer honoured once a second organization exists.
    # Until 0.12 this test asserted the opposite — lenient, with a warning —
    # which is the Host→default-org leak the audit flagged.
    test "false with two organizations is strict anyway, and says so as an error" do
      setting!(false)
      assert OrgCount.refresh() == 1
      refute Tenant.strict_host?()

      log = capture_log(fn -> assert {:ok, _} = create_org("explicit-off") end)

      assert OrgCount.verdict() == :multi
      assert Tenant.strict_host?()
      assert :error = Tenant.fetch_org(unknown_host())

      assert log =~ "[error]"
      assert log =~ "TENANT_STRICT_HOST=false"
      assert log =~ "no longer honours"
      assert Tenant.strict_host_false_ignored?()
      refute Tenant.strict_host_gap?()
    end

    test "false with two organizations refuses an unknown Host at the plug", %{conn: conn} do
      setting!(false)
      org("explicit-off-plug")
      assert OrgCount.refresh() == 2

      conn = %{conn | host: unknown_host()} |> get(~p"/")
      assert conn.status == 404
      assert conn.halted
    end

    # What `false` still does: lenient with one org, and lenient while nobody
    # has counted — the conservative half of #1662, which only overrides the
    # setting on a verdict that is actually `:multi`.
    test "false with one organization, or an unknown count, keeps the fallback" do
      setting!(false)

      OrgCount.put(:single)
      refute Tenant.strict_host?()
      assert {:ok, org} = Tenant.fetch_org(unknown_host())
      assert org.id == Accounts.default_org_id()

      OrgCount.put(:unknown)
      refute Tenant.strict_host?()
    end

    test "true with a single organization is strict" do
      setting!(true)
      OrgCount.put(:single)

      assert Tenant.strict_host?()
      assert :error = Tenant.fetch_org(unknown_host())
    end
  end

  describe "the verdict" do
    setup do: setting!(:auto)

    # Nobody has counted (boot with the database down). Lenient-but-actually
    # -multi would hand an attacker-chosen Host another tenant's site; strict
    # -but-actually-single refuses non-canonical hosts until the recount lands.
    test "an unknown count fails closed" do
      OrgCount.put(:unknown)

      assert Tenant.strict_host?()
      assert :error = Tenant.fetch_org(unknown_host())
    end

    test "only moves upwards: :multi is final" do
      OrgCount.put(:multi)

      assert OrgCount.refresh() == 1
      assert OrgCount.verdict() == :multi
    end

    test "a count that cannot be read never replaces a known answer" do
      assert OrgCount.verdict_for(:unknown) == :unknown

      OrgCount.put(:single)
      send(OrgCount, {:org_verdict, :elsewhere@nohost, :unknown})
      _ = :sys.get_state(OrgCount)

      assert OrgCount.verdict() == :single
    end

    test "the threshold is more than one" do
      assert OrgCount.verdict_for(0) == :single
      assert OrgCount.verdict_for(1) == :single
      assert OrgCount.verdict_for(2) == :multi
      assert OrgCount.verdict_for(50) == :multi
    end

    # Multi-node: the creating node broadcasts, every node's OrgCount records.
    test "another node's create reaches this one over PubSub" do
      OrgCount.put(:single)

      Phoenix.PubSub.broadcast(
        KilnCMS.PubSub,
        OrgCount.topic(),
        {:org_verdict, :other@nohost, :multi}
      )

      # A call is processed after the broadcast message already in the mailbox.
      _ = :sys.get_state(OrgCount)

      assert OrgCount.verdict() == :multi
      assert Tenant.strict_host?()
    end

    test "a create broadcasts its verdict to the other nodes" do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, OrgCount.topic())
      OrgCount.put(:single)

      assert {:ok, _} = create_org("auto-broadcast")

      node = node()
      assert_receive {:org_verdict, ^node, :multi}
    end

    # #1654: PubSub is at-most-once. A node that was partitioned or mid-boot when
    # the second org was created never hears the broadcast; the recount is what
    # flips it, and how long that takes is how long an unknown Host is still
    # served the default org there.
    test "a node that missed the broadcast turns strict on its next recount" do
      OrgCount.put(:single)
      # `Ash.Seed` skips `RecordOrgCount`: the second org exists and nobody told
      # this node — exactly the missed message.
      org("auto-missed")
      refute Tenant.strict_host?()

      # The recount runs in OrgCount's own process, outside this test's sandbox.
      Ecto.Adapters.SQL.Sandbox.allow(KilnCMS.Repo, self(), Process.whereis(OrgCount))
      send(OrgCount, :recount)
      # Processed after the `:recount` already in the mailbox.
      assert :sys.get_state(OrgCount) == nil, "a :multi verdict schedules no further recount"

      assert OrgCount.verdict() == :multi
      assert Tenant.strict_host?()
      assert :error = Tenant.fetch_org(unknown_host())
    end

    test "while :single, the next recount is due within 30 seconds" do
      OrgCount.put(:single)
      Ecto.Adapters.SQL.Sandbox.allow(KilnCMS.Repo, self(), Process.whereis(OrgCount))
      send(OrgCount, :recount)

      timer = :sys.get_state(OrgCount)
      assert is_reference(timer), "a :single verdict must schedule another recount"
      # Cancelled here so it cannot fire into a later test.
      remaining = Process.cancel_timer(timer)

      assert is_integer(remaining)
      assert remaining > 0 and remaining <= :timer.seconds(30)
      assert OrgCount.verdict() == :single
    end

    test "the recount interval: 30 seconds until :multi, then none" do
      assert OrgCount.recount_interval(:single) == :timer.seconds(30)
      assert OrgCount.recount_interval(:unknown) == :timer.seconds(30)
      assert OrgCount.recount_interval(:multi) == nil
    end

    test "with tracking off, a stray recount records nothing" do
      Application.put_env(:kiln_cms, :tenant_org_tracking, false)
      OrgCount.put(:single)
      org("auto-stray")
      Ecto.Adapters.SQL.Sandbox.allow(KilnCMS.Repo, self(), Process.whereis(OrgCount))

      send(OrgCount, :recount)
      assert :sys.get_state(OrgCount) == nil

      assert OrgCount.verdict() == :single
    end

    test "with tracking off, a create neither records nor broadcasts" do
      Application.put_env(:kiln_cms, :tenant_org_tracking, false)
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, OrgCount.topic())
      OrgCount.put(:single)

      assert {:ok, _} = create_org("auto-untracked")

      assert OrgCount.verdict() == :single
      refute_receive {:org_verdict, _, _}
    end

    # This node's own broadcast is ignored by its OrgCount: the creator already
    # recorded, in-process, where its sandboxed rows are visible.
    test "this node's own broadcast is a no-op" do
      OrgCount.put(:single)
      send(OrgCount, {:org_verdict, node(), :multi})
      _ = :sys.get_state(OrgCount)

      assert OrgCount.verdict() == :single
    end
  end
end
