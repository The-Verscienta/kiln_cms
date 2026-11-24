defmodule KilnCMS.OrgSettingsSystemActorTest do
  @moduledoc """
  The per-org settings resolvers (`Feeds`, `Compliance.Settings`, `Branding`,
  `CodeInjection`) read their row as `KilnCMS.OrgSettings.system/1` instead of
  `authorize?: false` (#1659).

  `FeedSettings` (admin-read) and `SiteCompliance` (editor-read) admit the
  system actor for `read` only, through `OrgSettings`' `system_actions:`; each
  grant has its refusal (the system cannot save the row). The branding and
  code-injection rows are world-readable, so there the system needs no grant.

  The fail-closed tests are the point. A refused read filters to "no row", and
  "no row" is the operator config, which the resolver CACHES for the whole
  TTL. So each one checks what the refusal answers AND that the next,
  unrefused, resolve still sees the site's own row, which is what a cached
  refusal would break.

  `async: false`: these write application env and the shared Cachex.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Compliance
  alias KilnCMS.Compliance.Settings
  alias KilnCMS.Feeds
  alias KilnCMS.OrgSettings
  alias KilnCMS.SystemActor

  setup do
    feeds = Application.get_env(:kiln_cms, :feeds, [])
    compliance = Application.get_env(:kiln_cms, Compliance, [])

    org = org("osa")

    on_exit(fn ->
      Application.put_env(:kiln_cms, :feeds, feeds)
      Application.put_env(:kiln_cms, Compliance, compliance)
      KilnCMS.Cache.bust_feed_policy(org.id)
      KilnCMS.Cache.bust_compliance(org.id)
      KilnCMS.Cache.bust_branding(org.id)
      KilnCMS.Cache.bust_code_injection(org.id)
    end)

    %{org: org, admin: admin()}
  end

  defp admin do
    Ash.Seed.seed!(Accounts.User, %{
      email: "osa-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  test "system/1 is a system actor labelled with the resolver's subsystem" do
    assert %SystemActor{subsystem: :feeds} = OrgSettings.system(:feeds)
    assert %SystemActor{subsystem: :compliance} = OrgSettings.system(:compliance)
  end

  test "with_actor/2 restores the real actor afterwards, even when the block raises" do
    assert_raise RuntimeError, fn -> OrgSettings.with_actor(nil, fn -> raise "boom" end) end
    assert %SystemActor{subsystem: :feeds} = OrgSettings.system(:feeds)
    assert OrgSettings.with_actor(nil, fn -> OrgSettings.system(:feeds) end) == nil
  end

  describe "with_actor/3, one subsystem's override (#2535)" do
    test "takes away only the subsystem it names" do
      OrgSettings.with_actor(:registrations, nil, fn ->
        assert OrgSettings.system(:registrations) == nil
        assert %SystemActor{subsystem: :admin_allowlist} = OrgSettings.system(:admin_allowlist)
        assert %SystemActor{subsystem: :branding} = OrgSettings.system(:branding)
      end)
    end

    test "is restored after a normal return and after a raise" do
      assert :done = OrgSettings.with_actor(:registrations, nil, fn -> :done end)
      assert %SystemActor{subsystem: :registrations} = OrgSettings.system(:registrations)

      assert_raise RuntimeError, fn ->
        OrgSettings.with_actor(:registrations, nil, fn -> raise "boom" end)
      end

      assert %SystemActor{subsystem: :registrations} = OrgSettings.system(:registrations)
    end

    test "nests: the inner override wins, and the outer one is back afterwards" do
      other = SystemActor.new(:feeds)

      OrgSettings.with_actor(:registrations, nil, fn ->
        OrgSettings.with_actor(:registrations, other, fn ->
          assert OrgSettings.system(:registrations) == other
        end)

        assert OrgSettings.system(:registrations) == nil
      end)

      assert %SystemActor{subsystem: :registrations} = OrgSettings.system(:registrations)
    end

    test "with_actor/2 answers for every subsystem, over a per-subsystem override" do
      other = SystemActor.new(:feeds)

      OrgSettings.with_actor(:registrations, other, fn ->
        OrgSettings.with_actor(nil, fn ->
          assert OrgSettings.system(:registrations) == nil
          assert OrgSettings.system(:admin_allowlist) == nil
        end)

        assert OrgSettings.system(:registrations) == other
      end)
    end

    # `:security` names both the retention row and the prune worker's grant;
    # a test that takes the worker's grant away must still read the window.
    test "is not SystemActor's override of the same name" do
      SystemActor.with_override(:security, nil, fn ->
        assert %SystemActor{subsystem: :security} = OrgSettings.system(:security)
      end)
    end

    test "refuses the registration read and leaves another resolver's read alone", ctx do
      alias KilnCMS.Accounts.RegistrationPolicy

      log =
        capture_log(fn ->
          OrgSettings.with_actor(:registrations, nil, fn ->
            assert RegistrationPolicy.settings(ctx.org.id) == {:error, :unavailable}
            assert KilnCMS.Security.AdminAllowlist.policy(ctx.org.id, :sign_in) == :off
          end)
        end)

      assert log =~ "registration approval lookup failed"
      refute log =~ "admin allowlist lookup failed"
    end
  end

  describe "FeedSettings" do
    test "the system reads the row but cannot save it; no actor reads nothing", ctx do
      row =
        CMS.save_feed_settings!(%{full_content_types: ["page"]},
          actor: ctx.admin,
          tenant: ctx.org
        )

      system = OrgSettings.system(:feeds)

      assert [%{id: id}] = CMS.list_feed_settings!(actor: system, tenant: ctx.org)
      assert id == row.id
      assert [] == CMS.list_feed_settings!(tenant: ctx.org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_feed_settings(%{full_content_types: ["post"]},
                 actor: system,
                 tenant: ctx.org
               )

      assert Feeds.policy(ctx.org).full_content == ["page"]
    end

    test "a refused read answers the fallback, never a cached operator config", ctx do
      Application.put_env(:kiln_cms, :feeds, full_content: ["post"])

      CMS.save_feed_settings!(%{full_content_types: [], excluded_types: ["page"]},
        actor: ctx.admin,
        tenant: ctx.org
      )

      log =
        capture_log(fn ->
          refused = OrgSettings.with_actor(nil, fn -> Feeds.policy(ctx.org) end)

          # Not the operator config's full content, which "no row" would give.
          assert refused.full_content == []
        end)

      assert log =~ "feed settings lookup failed"

      # And nothing was cached: the site's own row is back on the next resolve.
      assert Feeds.policy(ctx.org) == %Feeds.Policy{exclude: ["page"], full_content: []}
    end
  end

  describe "SiteCompliance" do
    test "the system reads the row but cannot save it; no actor reads nothing", ctx do
      {:ok, row} =
        CMS.save_site_compliance(%{enabled: true, phrases: ["guaranteed"]},
          actor: ctx.admin,
          tenant: ctx.org
        )

      system = OrgSettings.system(:compliance)

      assert [%{id: id}] = CMS.list_site_compliance!(actor: system, tenant: ctx.org)
      assert id == row.id
      assert [] == CMS.list_site_compliance!(tenant: ctx.org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_compliance(%{enabled: false}, actor: system, tenant: ctx.org)

      assert Settings.for_org(ctx.org).enabled?
    end

    test "a refused read answers unavailable/0 uncached, not the operator config", ctx do
      Application.put_env(:kiln_cms, Compliance, enabled: false)

      CMS.save_site_compliance!(%{enabled: true, require_at_publish: true, phrases: ["cure"]},
        actor: ctx.admin,
        tenant: ctx.org
      )

      log =
        capture_log(fn ->
          refused = OrgSettings.with_actor(nil, fn -> Settings.for_org(ctx.org) end)
          assert refused == Settings.unavailable()
        end)

      assert log =~ "compliance: could not read settings"

      # The refusal was not cached: the site's own gate is back.
      settings = Settings.for_org(ctx.org)
      assert settings.enabled?
      assert settings.require_at_publish?
    end

    test "the uncached publish-gate read fails closed the same way", ctx do
      CMS.save_site_compliance!(%{enabled: true, require_at_publish: true},
        actor: ctx.admin,
        tenant: ctx.org
      )

      capture_log(fn ->
        assert OrgSettings.with_actor(nil, fn -> Settings.for_org_uncached(ctx.org) end) ==
                 Settings.unavailable()
      end)

      assert Settings.for_org_uncached(ctx.org).require_at_publish?
    end
  end

  describe "world-readable rows need no grant" do
    test "branding and code injection resolve as the system", ctx do
      CMS.save_site_branding!(%{site_name: "OSA Site"}, actor: ctx.admin, tenant: ctx.org)
      KilnCMS.Cache.bust_branding(ctx.org.id)

      assert KilnCMS.Branding.for_org(ctx.org).site_name == "OSA Site"
      assert %KilnCMS.CodeInjection{} = KilnCMS.CodeInjection.for_org(ctx.org)
    end
  end
end
