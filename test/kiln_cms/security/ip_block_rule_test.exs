defmodule KilnCMS.Security.IpBlockRuleTest do
  @moduledoc """
  The `IpBlockRule` resource (#2242): normalisation and validation on write,
  org-admin-only policies on every action, tenant isolation, and that it is not
  an API surface.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.IpBlockRule

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ipb-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp add!(cidr, attrs \\ %{}, actor \\ nil) do
    CMS.create_ip_block_rule!(Map.put(attrs, :cidr, cidr),
      actor: actor || user(:admin),
      tenant: org_id(),
      context: %{client_ip: {192, 0, 2, 1}}
    )
  end

  describe "create" do
    test "stores the normalised cidr, note and expiry" do
      expires = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      rule = add!(" 203.0.113.9/24 ", %{note: "  scraper  ", expires_at: expires})

      assert rule.cidr == "203.0.113.0/24"
      assert rule.note == "scraper"
      assert rule.expires_at == expires
      assert rule.org_id == org_id()
    end

    test "a bare address and its mapped IPv6 spelling are the same rule" do
      add!("10.9.9.9")
      assert {:error, %Ash.Error.Invalid{} = error} = create("::ffff:10.9.9.9")
      assert Exception.message(error) =~ "already blocked"
    end

    test "refuses loopback, a too-wide range and garbage on the cidr field" do
      for {cidr, text} <- [
            {"127.0.0.1", "loopback"},
            {"::1", "loopback"},
            {"0.0.0.0/0", "too broad"},
            {"::/0", "too broad"},
            {"not an ip", "IP address"}
          ] do
        assert {:error, %Ash.Error.Invalid{errors: errors}} = create(cidr)
        assert Enum.any?(errors, &(Map.get(&1, :field) == :cidr))
        assert Exception.message(%Ash.Error.Invalid{errors: errors}) =~ text
      end
    end

    test "an expiry must be in the future" do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      assert {:error, %Ash.Error.Invalid{}} = create("192.0.2.1", %{expires_at: past})
    end

    test "org_id cannot be supplied" do
      assert {:error, %Ash.Error.Invalid{}} =
               create("192.0.2.2", %{org_id: Ash.UUID.generate()})
    end

    defp create(cidr, attrs \\ %{}) do
      CMS.create_ip_block_rule(Map.put(attrs, :cidr, cidr),
        actor: user(:admin),
        tenant: org_id(),
        context: %{client_ip: {192, 0, 2, 1}}
      )
    end
  end

  # A refused read filters to nothing by default (no row leaks either way);
  # `authorize_with: :error` is how a caller that must not mistake "refused" for
  # "empty" asks for the refusal itself.
  defp assert_read_refused(actor) do
    assert {:ok, []} = CMS.list_ip_block_rules(actor: actor, tenant: org_id())

    assert {:error, %Ash.Error.Forbidden{}} =
             CMS.list_ip_block_rules(actor: actor, tenant: org_id(), authorize_with: :error)
  end

  describe "policies" do
    test "an admin can create, list and destroy" do
      admin = user(:admin)
      rule = add!("198.51.100.0/24", %{}, admin)

      assert [%{id: id}] =
               CMS.list_ip_block_rules!(actor: admin, tenant: org_id())
               |> Enum.filter(&(&1.id == rule.id))

      assert id == rule.id
      assert :ok = CMS.destroy_ip_block_rule(rule, actor: admin, tenant: org_id())
    end

    for role <- [:editor, :viewer] do
      test "a #{role} is refused every action" do
        actor = user(unquote(role))
        rule = add!("198.51.100.#{System.unique_integer([:positive]) |> rem(200)}")

        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.create_ip_block_rule(%{cidr: "203.0.113.1"}, actor: actor, tenant: org_id())

        assert_read_refused(actor)

        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.destroy_ip_block_rule(rule, actor: actor, tenant: org_id())

        refute CMS.can_create_ip_block_rule?(actor, %{cidr: "203.0.113.1"}, tenant: org_id())
        refute CMS.can_destroy_ip_block_rule?(actor, rule, tenant: org_id())
      end
    end

    test "an anonymous caller is refused every action" do
      rule = add!("198.51.100.77")

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_ip_block_rule(%{cidr: "203.0.113.2"}, actor: nil, tenant: org_id())

      assert_read_refused(nil)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_ip_block_rule(rule, actor: nil, tenant: org_id())
    end

    test "the :ip_block system actor reads the list (and nothing else)" do
      actor = KilnCMS.SystemActor.new(:ip_block)
      rule = add!("203.0.113.3")

      assert [%{id: id}] =
               CMS.list_ip_block_rules!(actor: actor, tenant: org_id(), authorize_with: :error)

      assert id == rule.id

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_ip_block_rule(%{cidr: "203.0.113.4"}, actor: actor, tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_ip_block_rule(rule, actor: actor, tenant: org_id())
    end

    test "any other system actor is refused" do
      assert_read_refused(KilnCMS.SystemActor.new(:search))
    end

    test "the :scanner_guard system actor creates a rule and does nothing else (#2253)" do
      guard = KilnCMS.SystemActor.new(:scanner_guard)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      rule =
        CMS.create_ip_block_rule!(
          %{cidr: "203.0.113.20", expires_at: future, confirm_self_block: true},
          actor: guard,
          tenant: org_id()
        )

      assert rule.cidr == "203.0.113.20/32"

      assert_read_refused(guard)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_ip_block_rule(rule, actor: guard, tenant: org_id())
    end

    test "the :operator system actor lists and removes but cannot create (#2253)" do
      operator = KilnCMS.SystemActor.new(:operator)
      rule = add!("203.0.113.21")

      assert [%{id: id}] =
               CMS.list_ip_block_rules!(actor: operator, tenant: org_id(), authorize_with: :error)

      assert id == rule.id

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_ip_block_rule(%{cidr: "203.0.113.22", confirm_self_block: true},
                 actor: operator,
                 tenant: org_id()
               )

      assert :ok = CMS.destroy_ip_block_rule(rule, actor: operator, tenant: org_id())
    end

    test "the :ip_block system actor still cannot create (#2253)" do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_ip_block_rule(%{cidr: "203.0.113.23", confirm_self_block: true},
                 actor: KilnCMS.SystemActor.new(:ip_block),
                 tenant: org_id()
               )
    end
  end

  describe "re-adding a lapsed range" do
    defp seed_expired!(cidr, org) do
      Ash.Seed.seed!(IpBlockRule, %{
        cidr: cidr,
        org_id: org,
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      })
    end

    defp rules(org), do: CMS.list_ip_block_rules!(actor: user(:admin), tenant: org)

    test "an expired rule no longer holds the range" do
      old = seed_expired!("198.51.100.0/24", org_id())

      assert %{id: id} = add!("198.51.100.77/24")
      refute id == old.id

      assert [%{id: ^id, expires_at: nil}] =
               Enum.filter(rules(org_id()), &(&1.cidr == "198.51.100.0/24"))
    end

    test "an active rule still refuses a duplicate" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      add!("198.51.100.0/24", %{expires_at: future})

      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.create_ip_block_rule(%{cidr: "198.51.100.0/24"},
                 actor: user(:admin),
                 tenant: org_id(),
                 context: %{client_ip: {192, 0, 2, 1}}
               )

      assert Exception.message(error) =~ "already blocked"
    end

    test "a different range's expired rule is left alone" do
      other = seed_expired!("203.0.113.0/24", org_id())
      add!("198.51.100.0/24")
      assert Enum.any?(rules(org_id()), &(&1.id == other.id))
    end

    test "another org's expired rule is left alone" do
      theirs = KilnCMS.OrgFixtures.org("ipb-lapsed")
      stale = seed_expired!("198.51.100.0/24", theirs.id)

      add!("198.51.100.0/24")
      assert [%{id: id}] = rules(theirs.id)
      assert id == stale.id
    end
  end

  describe "tenancy" do
    test "a rule is invisible and undeletable from another org" do
      admin = user(:admin)
      other = KilnCMS.OrgFixtures.org("ipb-other")
      mine = add!("203.0.113.50", %{}, admin)

      assert CMS.list_ip_block_rules!(actor: admin, tenant: other.id) == []

      # By id under the wrong tenant the row does not exist.
      assert {:error, _} = CMS.get_ip_block_rule(mine.id, actor: admin, tenant: other.id)
      assert {:ok, %{id: id}} = CMS.get_ip_block_rule(mine.id, actor: admin, tenant: org_id())
      assert id == mine.id
    end

    test "the same range can be blocked independently in two orgs" do
      admin = user(:admin)
      other = KilnCMS.OrgFixtures.org("ipb-other")

      a = add!("203.0.113.60", %{}, admin)

      b =
        CMS.create_ip_block_rule!(%{cidr: "203.0.113.60"},
          actor: admin,
          tenant: other.id,
          context: %{client_ip: {192, 0, 2, 1}}
        )

      assert a.org_id == org_id()
      assert b.org_id == other.id
    end
  end

  describe "not an API surface" do
    test "absent from JSON:API, GraphQL and the MCP tools" do
      refute AshJsonApi.Resource in Spark.extensions(IpBlockRule)
      refute AshGraphql.Resource in Spark.extensions(IpBlockRule)

      refute Enum.any?(AshJsonApi.Domain.Info.routes(KilnCMS.CMS), &(&1.resource == IpBlockRule))
      refute Enum.any?(AshAi.Info.tools(KilnCMS.CMS), &(&1.resource == IpBlockRule))
    end
  end
end
