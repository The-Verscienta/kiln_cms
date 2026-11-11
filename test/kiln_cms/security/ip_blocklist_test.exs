defmodule KilnCMS.Security.IpBlocklistTest do
  @moduledoc """
  The matcher behind the IP block list (#2242): rules per org, IPv4/IPv6/mapped
  addresses, expiry at match time, the cache (warm path, bust), fail-open, and the
  self-lockout helper.

  `async: false`: the cache is one named Cachex instance per node.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.IpBlockRule
  alias KilnCMS.Security.IpBlocklist
  alias KilnCMS.Test.QueryCounting

  @moduletag :capture_log

  setup do
    IpBlocklist.clear()
    on_exit(&IpBlocklist.clear/0)
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ipbl-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp add!(cidr, org_id \\ org_id()) do
    CMS.create_ip_block_rule!(%{cidr: cidr},
      actor: admin(),
      tenant: org_id,
      context: %{client_ip: {192, 0, 2, 1}}
    )
  end

  describe "blocked?/2" do
    test "an org with no rules blocks nothing" do
      refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
    end

    test "matches an address and a range, and nothing outside them" do
      add!("203.0.113.9")
      add!("198.51.100.0/24")

      assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
      refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 10})
      assert IpBlocklist.blocked?(org_id(), {198, 51, 100, 200})
      refute IpBlocklist.blocked?(org_id(), {198, 51, 101, 1})
    end

    test "accepts an organization struct as well as its id" do
      add!("203.0.113.9")
      org = KilnCMS.Accounts.default_org()

      assert IpBlocklist.blocked?(org, {203, 0, 113, 9})
    end

    test "IPv6 ranges, and an IPv4-mapped IPv6 client against an IPv4 rule" do
      add!("2001:db8::/32")
      add!("203.0.113.0/24")

      assert IpBlocklist.blocked?(org_id(), {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      refute IpBlocklist.blocked?(org_id(), {0x2001, 0xDB9, 0, 0, 0, 0, 0, 1})
      # ::ffff:203.0.113.7
      assert IpBlocklist.blocked?(org_id(), {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107})
    end

    test "an IPv4 rule typed as a mapped IPv6 address blocks the IPv4 client" do
      add!("::ffff:203.0.113.9")

      assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
    end

    test "loopback is never blocked, and non-addresses match nothing" do
      add!("203.0.113.9")

      refute IpBlocklist.blocked?(org_id(), {127, 0, 0, 1})
      refute IpBlocklist.blocked?(org_id(), {0, 0, 0, 0, 0, 0, 0, 1})
      refute IpBlocklist.blocked?(org_id(), nil)
      refute IpBlocklist.blocked?(org_id(), "203.0.113.9")
      refute IpBlocklist.blocked?(nil, {203, 0, 113, 9})
    end

    test "rules are per org" do
      other = KilnCMS.OrgFixtures.org("ipbl-other")
      add!("203.0.113.9", other.id)

      assert IpBlocklist.blocked?(other.id, {203, 0, 113, 9})
      refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
    end

    test "a rule stops matching when it expires, judged at match time" do
      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      Ash.Seed.seed!(IpBlockRule, %{cidr: "203.0.113.1/32", expires_at: past, org_id: org_id()})
      Ash.Seed.seed!(IpBlockRule, %{cidr: "203.0.113.2/32", expires_at: future, org_id: org_id()})

      refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 1})
      assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 2})
    end
  end

  describe "the cache" do
    test "a warm check runs no database query" do
      add!("203.0.113.9")
      # The rule's bust reaches this node twice; the second must not land
      # after the warm-up.
      QueryCounting.settle_busts()
      assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})

      {_, queries} =
        QueryCounting.queries(fn ->
          assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
          refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 10})
        end)

      assert queries == []
    end

    test "an org with no rules is cached too: the second check reads nothing" do
      # A bust an earlier test sent must not land after the warm-up.
      QueryCounting.settle_busts()
      refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})

      {_, queries} =
        QueryCounting.queries(fn -> refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 9}) end)

      assert queries == []
    end

    test "adding and removing a rule busts the cached list" do
      refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})

      rule = add!("203.0.113.9")
      assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})

      CMS.destroy_ip_block_rule!(rule, actor: admin(), tenant: org_id())
      refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
    end

    test "the entry has a TTL, the backstop for a row removed by hand" do
      add!("203.0.113.9")
      assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})

      assert {:ok, ttl} = Cachex.ttl(IpBlocklist.cache_name(), "rules:#{org_id()}")
      assert is_integer(ttl) and ttl > 0 and ttl <= IpBlocklist.ttl()
    end
  end

  describe "when the rules cannot be read" do
    test "fails open, and does not cache the failure" do
      add!("203.0.113.9")

      # A system actor with no grant on the resource: the read is refused.
      refused = KilnCMS.SystemActor.new(:search)

      refute KilnCMS.SystemActor.with_override(:ip_block, refused, fn ->
               IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
             end)

      assert {:ok, nil} = Cachex.get(IpBlocklist.cache_name(), "rules:#{org_id()}")

      # Grant back: the very next check reads the list and blocks.
      assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
    end
  end

  describe "would_block?/2" do
    test "true when the rule contains the address, false when it does not" do
      assert IpBlocklist.would_block?("203.0.113.0/24", {203, 0, 113, 9})
      refute IpBlocklist.would_block?("203.0.113.0/24", {203, 0, 114, 9})
      assert IpBlocklist.would_block?("::ffff:203.0.113.0/120", {203, 0, 113, 9})
    end

    test "an unknown address cannot be shown to be outside the rule" do
      assert IpBlocklist.would_block?("203.0.113.0/24", nil)
    end

    test "an unparseable rule blocks nothing" do
      refute IpBlocklist.would_block?("nonsense", {203, 0, 113, 9})
      refute IpBlocklist.would_block?(nil, nil)
    end
  end

  describe "the self-lockout guard on create" do
    defp create(attrs, context) do
      CMS.create_ip_block_rule(attrs, actor: admin(), tenant: org_id(), context: context)
    end

    test "refuses a rule containing the caller's own address" do
      assert {:error, %Ash.Error.Invalid{} = error} =
               create(%{cidr: "203.0.113.0/24"}, %{client_ip: {203, 0, 113, 9}})

      assert Exception.message(error) =~ "lock you out"
      assert Enum.any?(error.errors, &(&1.field == :confirm_self_block))
    end

    test "refuses when the caller's address is unknown" do
      assert {:error, %Ash.Error.Invalid{} = error} = create(%{cidr: "203.0.113.0/24"}, %{})
      assert Exception.message(error) =~ "could not be determined"
    end

    test "accepts a rule that leaves the caller out" do
      assert {:ok, _} = create(%{cidr: "203.0.113.0/24"}, %{client_ip: {198, 51, 100, 1}})
    end

    test "accepts a self-block once confirmed, including an unknown address" do
      assert {:ok, _} =
               create(
                 %{cidr: "203.0.113.0/24", confirm_self_block: true},
                 %{client_ip: {203, 0, 113, 9}}
               )

      assert {:ok, _} = create(%{cidr: "198.51.100.0/24", confirm_self_block: true}, %{})
    end

    test "a mapped IPv6 caller is caught by an IPv4 rule" do
      assert {:error, %Ash.Error.Invalid{}} =
               create(%{cidr: "203.0.113.0/24"}, %{
                 client_ip: {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7109}
               })
    end
  end
end
