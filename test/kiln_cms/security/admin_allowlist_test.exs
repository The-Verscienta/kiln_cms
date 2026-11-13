defmodule KilnCMS.Security.AdminAllowlistTest do
  @moduledoc """
  `KilnCMS.Security.AdminAllowlist` (#2248): the compiled list the gates read —
  off, on, cached and busted by a save, per site, failing closed when the row
  cannot be read (except for a site last seen off), and the operator's switch.

  `async: false`: one test sets `Application.put_env(:kiln_cms,
  :admin_allowlist, ...)`, which is node-wide. Every test uses a site of its own,
  so its cached list cannot reach another test.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Security.AdminAllowlist

  @moduletag :capture_log

  @me {203, 0, 113, 7}
  @other {198, 51, 100, 9}

  defp admin(site) do
    user =
      Ash.Seed.seed!(Accounts.User, %{
        email: "aal-rt-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: site.id,
      user_id: user.id,
      role: :admin
    })

    user
  end

  defp save!(site, cidrs, saving_from \\ @me) do
    CMS.save_site_admin_allowlist!(%{cidrs: cidrs},
      actor: admin(site),
      tenant: site.id,
      context: %{client_ip: saving_from}
    )
  end

  # Only the compiled list's own key: the last-known copy stays.
  defp expire_cache(site),
    do: Cachex.del(KilnCMS.Cache.cache_name(), KilnCMS.Cache.admin_allowlist_key(site.id))

  test "a site with no row, or an empty list, is off and admits anyone" do
    site = org("aal-off")
    assert AdminAllowlist.policy(site.id) == :off
    assert AdminAllowlist.check(site.id, @other) == :allowed

    save!(site, [])
    assert AdminAllowlist.policy(site.id) == :off
    assert AdminAllowlist.check(site.id, nil) == :allowed
  end

  test "a list admits its networks only, and an unknown address never" do
    site = org("aal-on")
    save!(site, ["203.0.113.0/24"])

    assert {:on, [_]} = AdminAllowlist.policy(site.id)
    assert AdminAllowlist.check(site.id, @me) == :allowed
    assert AdminAllowlist.check(site.id, @other) == :not_listed
    assert AdminAllowlist.check(site.id, nil) == :not_listed
  end

  test "every address handed in must be listed" do
    policy = AdminAllowlist.from_cidrs(["203.0.113.0/24"])

    assert AdminAllowlist.verdict(policy, [@me, {203, 0, 113, 99}]) == :allowed
    assert AdminAllowlist.verdict(policy, [@me, @other]) == :not_listed
    assert AdminAllowlist.verdict(policy, [@me, nil]) == :not_listed
    assert AdminAllowlist.verdict(policy, []) == :not_listed
    assert AdminAllowlist.verdict(:off, [nil]) == :allowed
    assert AdminAllowlist.verdict(:unavailable, [@me]) == :unavailable
  end

  test "a stored setting with sign-in open is the list for the console and off for sign-in (#2493)" do
    {:on, cidrs} = AdminAllowlist.from_cidrs(["203.0.113.0/24"])
    stored = AdminAllowlist.from_row(%{cidrs: ["203.0.113.0/24"], restrict_sign_in: false})

    assert stored == {:console_only, cidrs}
    assert AdminAllowlist.for_surface(stored, :console) == {:on, cidrs}
    assert AdminAllowlist.for_surface(stored, :sign_in) == :off
    # An empty list is off whatever the setting; a missing setting restricts.
    assert AdminAllowlist.from_row(%{cidrs: [], restrict_sign_in: false}) == :off
    assert AdminAllowlist.from_row(%{cidrs: ["203.0.113.0/24"]}) == {:on, cidrs}
    # Reaching a gate unprojected, it is judged as the console would judge it.
    assert AdminAllowlist.verdict(stored, [@other]) == :not_listed
    assert AdminAllowlist.verdict(stored, [@me]) == :allowed
  end

  test "a stored entry that does not parse admits nothing, and does not turn the list off" do
    assert AdminAllowlist.from_cidrs(["not an address"]) == {:on, []}
    assert AdminAllowlist.verdict({:on, []}, [@me]) == :not_listed
  end

  test "the list is cached, and a save reaches the next check at once" do
    site = org("aal-cache")
    save!(site, ["203.0.113.0/24"])
    assert AdminAllowlist.check(site.id, @other) == :not_listed

    assert {:on, _} = KilnCMS.Cache.peek(KilnCMS.Cache.admin_allowlist_key(site.id))

    save!(site, ["203.0.113.0/24", "198.51.100.0/24"])
    assert AdminAllowlist.check(site.id, @other) == :allowed
  end

  test "one site's list is not another's" do
    a = org("aal-a")
    b = org("aal-b")
    save!(b, ["203.0.113.0/24"])

    assert AdminAllowlist.policy(a.id) == :off
    assert AdminAllowlist.check(a.id, @other) == :allowed
    assert AdminAllowlist.check(b.id, @other) == :not_listed

    save!(a, ["198.51.100.0/24"], @other)
    assert AdminAllowlist.check(b.id, @other) == :not_listed
    assert AdminAllowlist.check(a.id, @me) == :not_listed
  end

  describe "an unreadable list" do
    test "fails closed and is not cached; the next good read is served" do
      site = org("aal-closed")
      save!(site, ["203.0.113.0/24"])
      expire_cache(site)
      # Nothing known on this node yet.
      Cachex.del(
        KilnCMS.Cache.generation_cache_name(),
        KilnCMS.Cache.admin_allowlist_last_known_key(site.id)
      )

      assert KilnCMS.OrgSettings.with_actor(nil, fn -> AdminAllowlist.policy(site.id) end) ==
               :unavailable

      assert KilnCMS.OrgSettings.with_actor(nil, fn -> AdminAllowlist.check(site.id, @me) end) ==
               :unavailable

      assert KilnCMS.Cache.peek(KilnCMS.Cache.admin_allowlist_key(site.id)) == nil
      assert {:on, _} = AdminAllowlist.policy(site.id)
    end

    test "a site last read as off stays off" do
      site = org("aal-last-off")
      assert AdminAllowlist.policy(site.id) == :off
      expire_cache(site)

      assert KilnCMS.OrgSettings.with_actor(nil, fn -> AdminAllowlist.policy(site.id) end) == :off
    end

    test "a site last read as on stays closed, not on its old list" do
      site = org("aal-last-on")
      save!(site, ["203.0.113.0/24"])
      assert {:on, _} = AdminAllowlist.policy(site.id)
      expire_cache(site)

      assert KilnCMS.OrgSettings.with_actor(nil, fn -> AdminAllowlist.policy(site.id) end) ==
               :unavailable
    end

    test "a site last read with sign-in open stays closed on both surfaces (#2493)" do
      site = org("aal-last-console-only")

      CMS.save_site_admin_allowlist!(%{cidrs: ["203.0.113.0/24"], restrict_sign_in: false},
        actor: admin(site),
        tenant: site.id,
        context: %{client_ip: @me}
      )

      assert AdminAllowlist.policy(site.id, :sign_in) == :off
      expire_cache(site)

      for surface <- [:console, :sign_in] do
        assert KilnCMS.OrgSettings.with_actor(nil, fn ->
                 AdminAllowlist.policy(site.id, surface)
               end) == :unavailable
      end
    end

    test "a save forgets the last-known value, so a list turned on is never read as off" do
      site = org("aal-turned-on")
      assert AdminAllowlist.policy(site.id) == :off
      save!(site, ["203.0.113.0/24"])

      assert KilnCMS.OrgSettings.with_actor(nil, fn -> AdminAllowlist.policy(site.id) end) ==
               :unavailable
    end
  end

  # #2502: the last-known copy lives in the generation store, so neither a
  # delivery-cache clear nor its size cap's eviction can erase it. Erased, a
  # site last seen off would fail closed in an outage, and the version that
  # stops a late read writing an old list back would be gone.
  describe "the last-known value, after the delivery cache is emptied" do
    test "keeps a site last read as off off through a failed read" do
      site = org("aal-clear-off")
      assert AdminAllowlist.policy(site.id) == :off

      KilnCMS.Cache.bust_published()

      assert KilnCMS.OrgSettings.with_actor(nil, fn -> AdminAllowlist.policy(site.id) end) == :off
    end

    # Eviction drops entries one by one, oldest-written first; a whole clear
    # of the delivery instance stands in for it.
    test "keeps the version that refuses a late read of the old list" do
      site = org("aal-evicted")
      assert AdminAllowlist.policy(site.id) == :off
      save!(site, ["203.0.113.0/24"])

      Cachex.clear(KilnCMS.Cache.cache_name())
      AdminAllowlist.remember_read(site.id, nil)
      expire_cache(site)

      assert KilnCMS.OrgSettings.with_actor(nil, fn -> AdminAllowlist.policy(site.id) end) ==
               :unavailable
    end
  end

  describe "a read that finishes after a save" do
    test "each save moves the version on" do
      site = org("aal-version")
      first = save!(site, ["203.0.113.0/24"])
      Process.sleep(2)
      second = save!(site, [])

      assert DateTime.compare(second.updated_at, first.updated_at) == :gt

      assert KilnCMS.Cache.peek(KilnCMS.Cache.admin_allowlist_last_known_key(site.id)) ==
               {second.updated_at, :off}
    end

    test "cannot write the list from before the save back as the last-known value" do
      site = org("aal-late-read")
      # A read began while the site had no list ("off")...
      assert AdminAllowlist.policy(site.id) == :off
      # ...the list is turned on and the save busts every node...
      save!(site, ["203.0.113.0/24"])
      # ...and the read that began first lands now, with what it saw.
      AdminAllowlist.remember_read(site.id, nil)
      expire_cache(site)

      assert KilnCMS.OrgSettings.with_actor(nil, fn -> AdminAllowlist.policy(site.id) end) ==
               :unavailable
    end

    test "a read of the current version is kept" do
      site = org("aal-current-read")
      row = save!(site, [])
      AdminAllowlist.remember_read(site.id, row)
      expire_cache(site)

      assert KilnCMS.OrgSettings.with_actor(nil, fn -> AdminAllowlist.policy(site.id) end) == :off
    end

    # Inside a transaction `KilnCMS.Cache` reads on the caller's connection
    # (#2823), so the row may be uncommitted and still roll back: it is never
    # pinned as the last-known list.
    test "a read inside a transaction is not remembered" do
      site = org("aal-in-transaction")
      key = KilnCMS.Cache.admin_allowlist_last_known_key(site.id)
      assert KilnCMS.Cache.peek(key) == nil

      assert {:ok, :off} =
               KilnCMS.Repo.transaction(fn -> AdminAllowlist.remember_read(site.id, nil) end)

      assert KilnCMS.Cache.peek(key) == nil

      assert AdminAllowlist.remember_read(site.id, nil) == :off
      assert {_version, :off} = KilnCMS.Cache.peek(key)
    end
  end

  describe "the operator's switch" do
    # `put_env` is node-wide: this module is `async: false` for it.
    setup do
      previous = Application.get_env(:kiln_cms, :admin_allowlist)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, :admin_allowlist, previous),
          else: Application.delete_env(:kiln_cms, :admin_allowlist)
      end)
    end

    test "KILN_ADMIN_ALLOWLIST_DISABLED makes every list off on this node" do
      site = org("aal-disabled")
      save!(site, ["203.0.113.0/24"])
      Application.put_env(:kiln_cms, :admin_allowlist, disabled: true)

      assert AdminAllowlist.disabled?()
      assert AdminAllowlist.policy(site.id) == :off
      assert AdminAllowlist.check(site.id, @other) == :allowed
    end
  end

  test "would_admit?/2 is the save's view: off admits all, on admits its own" do
    assert AdminAllowlist.would_admit?([], nil)
    assert AdminAllowlist.would_admit?(["203.0.113.0/24"], @me)
    refute AdminAllowlist.would_admit?(["203.0.113.0/24"], @other)
    refute AdminAllowlist.would_admit?(["203.0.113.0/24"], nil)
  end
end
