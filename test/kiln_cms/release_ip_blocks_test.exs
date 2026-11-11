defmodule KilnCMS.ReleaseIpBlocksTest do
  @moduledoc """
  `KilnCMS.Release.ip_blocks/1` (#2242): the operator's way back in after an
  admin blocks their own network. Lists, or removes one rule or all, as the
  `:operator` system actor through the resource's code interface, and busts the
  site's cache.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureIO

  alias KilnCMS.CMS
  alias KilnCMS.Release
  alias KilnCMS.Security.IpBlocklist

  @cidr "203.0.113.0/24"

  setup do
    IpBlocklist.clear()
    :ok
  end

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp add!(cidr, attrs \\ %{}) do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "ipb-rel-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    CMS.create_ip_block_rule!(Map.put(attrs, :cidr, cidr),
      actor: admin,
      tenant: org_id(),
      context: %{client_ip: {192, 0, 2, 1}}
    )
  end

  defp run(opts, serving? \\ true) do
    test = self()
    out = capture_io(fn -> send(test, {:result, Release.run_ip_blocks(opts, serving?)}) end)
    assert_received {:result, result}
    {result, out}
  end

  defp cidrs do
    [actor: KilnCMS.SystemActor.new(:operator), tenant: org_id(), authorize_with: :error]
    |> CMS.list_ip_block_rules!()
    |> Enum.map(& &1.cidr)
    |> Enum.sort()
  end

  test "lists the rules and removes nothing" do
    add!(@cidr, %{note: "scraper"})
    add!("198.51.100.7")

    {{:ok, rules}, out} = run([])

    assert length(rules) == 2
    assert out =~ "203.0.113.0/24"
    assert out =~ "scraper"
    assert out =~ "Nothing removed"
    assert cidrs() == ["198.51.100.7/32", @cidr]
  end

  test "says so when there are no rules" do
    assert {{:ok, []}, out} = run([])
    assert out =~ "No block rules"
  end

  test "remove: true with a cidr removes that rule only, in any spelling" do
    add!(@cidr)
    add!("198.51.100.7")

    assert {{:ok, [%{cidr: @cidr}]}, out} = run(cidr: "203.0.113.9/24", remove: true)

    assert out =~ "removed #{@cidr}"
    assert cidrs() == ["198.51.100.7/32"]
  end

  test "remove: true alone clears every rule" do
    add!(@cidr)
    add!("198.51.100.7")

    assert {{:ok, rules}, out} = run(remove: true)

    assert length(rules) == 2
    assert out =~ "Removed 2 block rule(s)"
    assert cidrs() == []
  end

  test "removing the rule unblocks the address at once, without waiting for the TTL" do
    add!(@cidr)
    assert IpBlocklist.blocked?(org_id(), {203, 0, 113, 5})

    {{:ok, _}, _out} = run(remove: true)

    refute IpBlocklist.blocked?(org_id(), {203, 0, 113, 5})
  end

  test "an unknown cidr, a malformed one and an unknown org are errors, and remove nothing" do
    add!(@cidr)

    assert {{:error, msg}, out} = run(cidr: "198.51.100.7", remove: true)
    assert msg =~ "No block rule for 198.51.100.7/32"
    assert out =~ msg

    assert {{:error, msg}, _} = run(cidr: "not an ip", remove: true)
    assert msg =~ "not an IP address"

    assert {{:error, "No organization with slug nope"}, _} = run(org: "nope", remove: true)

    assert cidrs() == [@cidr]
  end

  test "refuses on a bare eval node, where the cache bust cannot reach the cluster" do
    add!(@cidr)

    assert {{:error, msg}, out} = run([remove: true], false)

    assert msg =~ "rpc"
    assert out =~ msg
    assert cidrs() == [@cidr]
  end

  test "the :operator actor can list and destroy but not create" do
    actor = KilnCMS.SystemActor.new(:operator)

    assert {:error, %Ash.Error.Forbidden{}} =
             CMS.create_ip_block_rule(%{cidr: "198.51.100.9"},
               actor: actor,
               tenant: org_id(),
               context: %{client_ip: {192, 0, 2, 1}}
             )
  end
end
