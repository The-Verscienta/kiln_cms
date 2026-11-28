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
  alias KilnCMS.Test.Latch
  alias KilnCMS.Test.QueryCounting

  @moduletag :capture_log

  @fill_latch __MODULE__.FillLatch

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

  describe "match/2 and the rule's source (#2810)" do
    # The scanner guard's rule, written by its own system actor so `source`
    # is set the way production sets it.
    defp guard_add!(cidr) do
      CMS.create_ip_block_rule!(
        %{
          cidr: cidr,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          confirm_self_block: true
        },
        actor: KilnCMS.SystemActor.new(:scanner_guard),
        tenant: org_id()
      )
    end

    defp lapse!(rule) do
      KilnCMS.Repo.query!(
        "UPDATE ip_block_rules SET expires_at = now() - interval '1 minute' WHERE id = $1",
        [Ecto.UUID.dump!(rule.id)]
      )

      IpBlocklist.clear()
    end

    test "names the rule and who added it" do
      add!("198.51.100.0/24")
      guard_add!("203.0.113.9")

      assert IpBlocklist.match(org_id(), {198, 51, 100, 7}) ==
               {:blocked, "198.51.100.0/24", :admin}

      assert IpBlocklist.match(org_id(), {203, 0, 113, 9}) ==
               {:blocked, "203.0.113.9/32", :scanner_guard}

      assert IpBlocklist.match(org_id(), {192, 0, 2, 200}) == false
    end

    test "an admin range wins over the scanner guard's address inside it, added after" do
      add!("203.0.113.0/24")
      guard_add!("203.0.113.9")

      assert IpBlocklist.match(org_id(), {203, 0, 113, 9}) ==
               {:blocked, "203.0.113.0/24", :admin}
    end

    test "an admin range wins over the scanner guard's address inside it, added before" do
      guard_add!("203.0.113.9")
      add!("203.0.113.0/24")

      assert IpBlocklist.match(org_id(), {203, 0, 113, 9}) ==
               {:blocked, "203.0.113.0/24", :admin}
    end

    test "the scanner guard's lapsed rule matches nothing" do
      "203.0.113.9" |> guard_add!() |> lapse!()

      assert IpBlocklist.match(org_id(), {203, 0, 113, 9}) == false
      refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
    end

    test "the scanner guard's lapsed rule leaves an active admin rule to match" do
      add!("203.0.113.0/24")
      "203.0.113.9" |> guard_add!() |> lapse!()

      assert IpBlocklist.match(org_id(), {203, 0, 113, 9}) ==
               {:blocked, "203.0.113.0/24", :admin}
    end
  end

  describe "the cache" do
    test "a warm check runs no database query" do
      add!("203.0.113.9")
      # The rule's bust reaches this node twice; `warm_up/1` lets the second
      # land before the warm-up, not after it.
      QueryCounting.warm_up(fn -> assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 9}) end)

      {_, queries} =
        QueryCounting.queries(fn ->
          assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
          refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 10})
        end)

      assert queries == []
    end

    test "an org with no rules is cached too: the second check reads nothing" do
      # A bust an earlier test sent must not land after the warm-up.
      QueryCounting.warm_up(fn -> refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 9}) end)

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
      # The rule's bust reaches this node twice, and a fill that begins
      # before the second is (rightly) not stored: let it land first.
      _ = :sys.get_state(KilnCMS.Cache.ClusterBust)
      assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})

      assert {:ok, ttl} = Cachex.ttl(IpBlocklist.cache_name(), "rules:#{org_id()}")
      assert is_integer(ttl) and ttl > 0 and ttl <= IpBlocklist.ttl()
    end
  end

  # #2972: a fill whose read ran before a write committed must not store the
  # list it read after that write's bust. The fill runs in a task; a telemetry
  # handler holds it, in that task, right after its read of the rules returns
  # and before it stores. The test writes and lets the bust run on both ends
  # (the local delete and this node's own `ClusterBust` subscriber), then
  # releases the fill.
  describe "a fill that read before a write's bust" do
    setup do
      start_supervised!({Latch, name: @fill_latch, listener: self()})
      handler = "ip-blocklist-fill-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(handler, [:ash, :cms, :read, :stop], &__MODULE__.hold_fill/4, nil)

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    defp start_held_check(ip) do
      task =
        Task.async(fn ->
          Process.put(:hold_ip_blocklist_fill, true)
          IpBlocklist.blocked?(org_id(), ip)
        end)

      assert_receive {:latch_started, @fill_latch, 1}, 2_000
      task
    end

    defp flush_busts, do: _ = :sys.get_state(KilnCMS.Cache.ClusterBust)

    defp release_and_await(task) do
      assert [_fill] = Latch.release_all(@fill_latch)
      result = Task.await(task, 5_000)
      refute_received {:latch_timeout, _, _}
      result
    end

    defp cached, do: Cachex.get(IpBlocklist.cache_name(), "rules:#{org_id()}")

    test "a rule added meanwhile is enforced on the next check" do
      task = start_held_check({203, 0, 113, 9})

      add!("203.0.113.9")
      flush_busts()

      # The check that read before the commit answers from what it read...
      refute release_and_await(task)
      # ...and stores none of it, so the next check reads the new rule.
      assert {:ok, nil} = cached()
      assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
    end

    test "a rule removed meanwhile stops matching on the next check" do
      rule = add!("203.0.113.9")
      flush_busts()
      task = start_held_check({203, 0, 113, 9})

      CMS.destroy_ip_block_rule!(rule, actor: admin(), tenant: org_id())
      flush_busts()

      assert release_and_await(task)
      assert {:ok, nil} = cached()
      refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
    end

    test "a bust from another node keeps the fill out too" do
      task = start_held_check({203, 0, 113, 9})

      # Written on another node: no bust here but the cluster message.
      Ash.Seed.seed!(IpBlockRule, %{cidr: "203.0.113.9/32", org_id: org_id()})

      send(
        KilnCMS.Cache.ClusterBust,
        {:bust_cache_keys, IpBlocklist.cache_name(), ["rules:#{org_id()}"]}
      )

      flush_busts()

      refute release_and_await(task)
      assert {:ok, nil} = cached()
      assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 9})
    end

    test "a fill no bust touched is stored" do
      task = start_held_check({203, 0, 113, 9})

      refute release_and_await(task)
      assert {:ok, []} = cached()
    end
  end

  @doc false
  def hold_fill(_event, _measurements, %{resource: IpBlockRule}, _config) do
    if Process.get(:hold_ip_blocklist_fill), do: Latch.enter(@fill_latch)
  end

  def hold_fill(_event, _measurements, _metadata, _config), do: :ok

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
