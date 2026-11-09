defmodule KilnCMS.Security.SiteAdminAllowlistTest do
  @moduledoc """
  The `SiteAdminAllowlist` resource (#2248): who may read and write it, the
  normalisation and the lock-out refusal on save, the audit events, and the
  operator's override, which may only widen or empty a list.

  Each test seeds its own site, so nothing here can leak a cached list into
  the default org another test is signing in to.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.SiteAdminAllowlist
  alias KilnCMS.Security

  @me {203, 0, 113, 7}

  setup do
    site = org("aal")
    %{site: site, admin: member!(user(:viewer), site, :admin)}
  end

  defp user(role) do
    Ash.Seed.seed!(Accounts.User, %{
      email: "aal-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp member!(user, org, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      organization_id: org.id,
      user_id: user.id,
      role: role
    })

    user
  end

  defp save(cidrs, actor, site, context \\ %{client_ip: @me}) do
    CMS.save_site_admin_allowlist(%{cidrs: cidrs},
      actor: actor,
      tenant: site.id,
      context: context
    )
  end

  defp stored(site) do
    case CMS.list_site_admin_allowlist(
           actor: KilnCMS.SystemActor.new(:operator),
           tenant: site.id,
           authorize_with: :error
         ) do
      {:ok, [row]} -> row.cidrs
      {:ok, []} -> nil
    end
  end

  defp events(site, type) do
    Security.list_events!(actor: user(:admin), tenant: site.id, page: [limit: 50])
    |> then(fn
      %{results: results} -> results
      list -> list
    end)
    |> Enum.filter(&(&1.type == type))
  end

  defp messages(error), do: Exception.message(error)

  # The messages are fixed templates (the console maps them to translated
  # sentences); what they name travels in `vars`.
  defp cidrs_errors(%{errors: errors}) do
    for %{field: :cidrs} = error <- errors,
        do: {error.message, Map.new(Map.get(error, :vars) || [])}
  end

  describe "who may write it" do
    test "an editor, a viewer and an anonymous caller are refused, and nothing is stored", %{
      site: site
    } do
      for actor <- [
            member!(user(:viewer), site, :editor),
            member!(user(:viewer), site, :viewer),
            nil
          ] do
        assert {:error, %Ash.Error.Forbidden{}} = save(["203.0.113.0/24"], actor, site)
      end

      assert stored(site) == nil
    end

    test "an admin of another site is refused here, and this site's list is unchanged", %{
      site: site,
      admin: admin
    } do
      assert {:ok, _} = save(["203.0.113.0/24"], admin, site)

      other = org("aal-other")
      other_admin = member!(user(:viewer), other, :admin)

      assert {:error, %Ash.Error.Forbidden{}} = save(["198.51.100.0/24"], other_admin, site)
      assert stored(site) == ["203.0.113.0/24"]
    end

    test "editors and viewers cannot read it; the admin can", %{site: site, admin: admin} do
      assert {:ok, _} = save(["203.0.113.0/24"], admin, site)

      for role <- [:editor, :viewer] do
        actor = member!(user(:viewer), site, role)

        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.list_site_admin_allowlist(
                   actor: actor,
                   tenant: site.id,
                   authorize_with: :error
                 )
      end

      assert {:ok, [%{cidrs: ["203.0.113.0/24"]}]} =
               CMS.list_site_admin_allowlist(actor: admin, tenant: site.id)
    end

    test "no one may destroy it, an admin included: off is an empty list", %{
      site: site,
      admin: admin
    } do
      assert {:ok, row} = save(["203.0.113.0/24"], admin, site)

      refute Ash.can?({row, :destroy}, admin, tenant: site.id)
      assert stored(site) == ["203.0.113.0/24"]
    end

    test "the lock-out check runs after the policy: an editor is told forbidden, not lockout",
         %{site: site} do
      editor = member!(user(:viewer), site, :editor)
      assert {:error, %Ash.Error.Forbidden{}} = save(["198.51.100.0/24"], editor, site)
    end
  end

  describe "saving" do
    test "entries are normalised, trimmed and de-duplicated, order kept", %{
      site: site,
      admin: admin
    } do
      assert {:ok, row} =
               save(
                 [" 203.0.113.7 ", "198.51.100.9/24", "::ffff:203.0.113.7", "2001:DB8::1/64"],
                 admin,
                 site
               )

      assert row.cidrs == ["203.0.113.7/32", "198.51.100.0/24", "2001:db8::/64"]
    end

    test "too broad, loopback and garbage are refused on :cidrs, naming the entry", %{
      site: site,
      admin: admin
    } do
      for {entry, message} <- [
            {"0.0.0.0/7", "%{entry} is too broad"},
            {"::1", "%{entry} includes loopback"},
            {"127.0.0.1", "%{entry} includes loopback"},
            {"office", "%{entry} is not an IP address or range"}
          ] do
        assert {:error, %Ash.Error.Invalid{} = error} =
                 save(["203.0.113.0/24", entry], admin, site)

        assert cidrs_errors(error) == [{message, %{entry: entry}}]
      end

      assert stored(site) == nil
    end

    test "more than #{SiteAdminAllowlist.max_entries()} entries is refused", %{
      site: site,
      admin: admin
    } do
      many =
        for n <- 0..SiteAdminAllowlist.max_entries(), do: "203.0.#{div(n, 256)}.#{rem(n, 256)}"

      assert {:error, %Ash.Error.Invalid{} = error} = save(["203.0.113.7" | many], admin, site)
      assert [{"at most %{max} entries", %{max: max}}] = cidrs_errors(error)
      assert max == SiteAdminAllowlist.max_entries()
      assert stored(site) == nil
    end

    test "duplicates don't count toward the cap", %{site: site, admin: admin} do
      max = SiteAdminAllowlist.max_entries()
      entries = for n <- 1..(max - 1), do: "203.0.#{div(n, 256)}.#{rem(n, 256)}"
      assert {:ok, _} = save(["203.0.113.7" | entries ++ entries], admin, site)
      assert length(stored(site)) == max
    end
  end

  describe "the lock-out check" do
    test "a list without the saver's address is refused, naming it; the row is unchanged", %{
      site: site,
      admin: admin
    } do
      assert {:ok, _} = save(["203.0.113.0/24"], admin, site)

      assert {:error, %Ash.Error.Invalid{} = error} = save(["198.51.100.0/24"], admin, site)

      assert [{message, %{ip: "203.0.113.7"}}] = cidrs_errors(error)
      assert message =~ "doesn't include your current address, %{ip}"
      assert stored(site) == ["203.0.113.0/24"]
    end

    test "an unknown address refuses any non-empty list", %{site: site, admin: admin} do
      assert {:error, error} = save(["203.0.113.0/24"], admin, site, %{})
      assert messages(error) =~ "could not be determined"
      assert stored(site) == nil
    end

    test "untrusted forwarding refuses, even with the address on the list", %{
      site: site,
      admin: admin
    } do
      assert {:error, error} =
               save(["203.0.113.0/24"], admin, site, %{
                 client_ip: @me,
                 untrusted_forwarding?: true
               })

      assert messages(error) =~ "proxy's address"
      assert stored(site) == nil
    end

    test "both addresses must be admitted: a dual-stack mismatch is refused, naming both", %{
      site: site,
      admin: admin
    } do
      v6 = {0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}

      assert {:error, error} =
               save(["203.0.113.0/24"], admin, site, %{client_ip: @me, socket_ip: v6})

      assert [{message, %{ip: "203.0.113.7", socket_ip: "2001:db8:1:2:3:4:5:6"}}] =
               cidrs_errors(error)

      assert message =~ "both of your current addresses"

      assert {:ok, row} =
               save(["203.0.113.0/24", "2001:db8:1:2::/64"], admin, site, %{
                 client_ip: @me,
                 socket_ip: v6
               })

      assert row.cidrs == ["203.0.113.0/24", "2001:db8:1:2::/64"]
    end

    test "an IPv4-mapped client is admitted by its IPv4 entry", %{site: site, admin: admin} do
      mapped = {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}
      assert {:ok, _} = save(["203.0.113.0/24"], admin, site, %{client_ip: mapped})
    end

    test "an empty list is always accepted: turning it off cannot lock anyone out", %{
      site: site,
      admin: admin
    } do
      assert {:ok, _} = save(["203.0.113.0/24"], admin, site)
      assert {:ok, %{cidrs: []}} = save([], admin, site, %{untrusted_forwarding?: true})
    end
  end

  describe "the audit trail" do
    test "a save records admin_allowlist_changed with counts and state, never the entries", %{
      site: site,
      admin: admin
    } do
      assert {:ok, _} = save(["203.0.113.0/24", "198.51.100.0/24"], admin, site)
      assert {:ok, _} = save(["203.0.113.0/24", "192.0.2.0/24", "2001:db8::/32"], admin, site)
      assert {:ok, _} = save([], admin, site)

      events =
        site
        |> events(:admin_allowlist_changed)
        |> Enum.sort_by(& &1.metadata["count"], :desc)

      assert [
               %{"state" => "on", "count" => 3, "added" => 2, "removed" => 1},
               %{"state" => "on", "count" => 2, "added" => 2, "removed" => 0},
               %{"state" => "off", "count" => 0, "added" => 0, "removed" => 3}
             ] = Enum.map(events, &normalise_metadata/1)

      assert Enum.all?(events, &(&1.actor_id == admin.id))
      refute inspect(Enum.map(events, & &1.metadata)) =~ "203.0.113"

      # One event per save: the generic org_setting_changed is replaced, not added.
      assert events(site, :org_setting_changed) == []
    end

    test "a refused save records nothing", %{site: site, admin: admin} do
      assert {:error, _} = save(["198.51.100.0/24"], admin, site)
      assert events(site, :admin_allowlist_changed) == []
    end
  end

  describe "the operator's override" do
    setup %{site: site, admin: admin} do
      {:ok, _} = save(["203.0.113.0/24"], admin, site)
      {:ok, [row]} = CMS.list_site_admin_allowlist(actor: admin, tenant: site.id)
      %{row: row}
    end

    defp override(row, site, args, actor \\ KilnCMS.SystemActor.new(:operator)),
      do: CMS.override_site_admin_allowlist(row, args, actor: actor, tenant: site.id)

    test "an admin is refused it, and so is any other system actor", %{
      site: site,
      admin: admin,
      row: row
    } do
      assert {:error, %Ash.Error.Forbidden{}} = override(row, site, %{clear: true}, admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               override(row, site, %{clear: true}, KilnCMS.SystemActor.new(:admin_allowlist))

      assert stored(site) == ["203.0.113.0/24"]
    end

    test "clear empties the list and records admin_allowlist_overridden", %{site: site, row: row} do
      assert {:ok, %{cidrs: []}} = override(row, site, %{clear: true})

      assert [event] = events(site, :admin_allowlist_overridden)
      assert normalise_metadata(event) == %{"change" => "cleared", "count" => 0}
      assert is_nil(event.actor_id)
      assert event.target_type == "organization"
      assert events(site, :admin_allowlist_changed) |> length() == 1
    end

    test "add widens an active list, normalised; an entry already listed is refused", %{
      site: site,
      row: row
    } do
      assert {:ok, row} = override(row, site, %{add: "198.51.100.9"})
      assert row.cidrs == ["203.0.113.0/24", "198.51.100.9/32"]
      assert {:error, %Ash.Error.Invalid{}} = override(row, site, %{add: "203.0.113.0/24"})
      assert stored(site) == ["203.0.113.0/24", "198.51.100.9/32"]

      assert [_] = events(site, :admin_allowlist_overridden)
    end

    test "add widens the list as stored now, not as the caller read it", %{
      site: site,
      admin: admin,
      row: stale
    } do
      # A console save lands between the operator reading the row and adding.
      assert {:ok, _} = save(["203.0.113.0/24", "192.0.2.0/24"], admin, site)

      assert {:ok, row} = override(stale, site, %{add: "198.51.100.9"})
      assert row.cidrs == ["203.0.113.0/24", "192.0.2.0/24", "198.51.100.9/32"]
      assert stored(site) == row.cidrs
    end

    test "add to a list that is off is refused: it would turn the list on", %{
      site: site,
      admin: admin
    } do
      assert {:ok, off} = save([], admin, site)
      assert {:error, error} = override(off, site, %{add: "198.51.100.9"})
      assert messages(error) =~ "off on this site"
      assert stored(site) == []
      assert events(site, :admin_allowlist_overridden) == []
    end

    test "both or neither argument is refused, and a bad entry is too", %{site: site, row: row} do
      assert {:error, _} = override(row, site, %{add: "198.51.100.9", clear: true})
      assert {:error, _} = override(row, site, %{})
      assert {:error, error} = override(row, site, %{add: "0.0.0.0/0"})
      assert messages(error) =~ "too broad"
      assert stored(site) == ["203.0.113.0/24"]
    end
  end

  describe "not an API surface" do
    test "absent from JSON:API, GraphQL and the MCP tools" do
      refute AshJsonApi.Resource in Spark.extensions(SiteAdminAllowlist)
      refute AshGraphql.Resource in Spark.extensions(SiteAdminAllowlist)
      refute Enum.any?(AshAi.Info.tools(KilnCMS.CMS), &(&1.resource == SiteAdminAllowlist))
    end
  end

  # Stored metadata comes back with string keys and, depending on the path,
  # integer or string values.
  defp normalise_metadata(%{metadata: metadata}), do: normalise_metadata(metadata)

  defp normalise_metadata(metadata) do
    Map.new(metadata, fn
      {key, value} when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> {key, int}
          _ -> {key, value}
        end

      pair ->
        pair
    end)
  end
end
