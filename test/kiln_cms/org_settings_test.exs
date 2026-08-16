defmodule KilnCMS.OrgSettingsTest do
  @moduledoc """
  The two shared halves of the per-org settings pattern (#1080): the resource
  mixin `KilnCMS.CMS.OrgSettings`, and the cached, layered read
  `KilnCMS.OrgSettings.resolve/2`.

  The resolver tests drive `resolve/2` with stub `read`/`build`/`fallback`
  functions rather than through Branding/CodeInjection/Feeds, so what they pin
  is the mechanism the three share — never cache a `nil`, degrade on a raise,
  cache "no row" — and not any one setting's layering, which its own suite
  covers. `async: false` because they write real cache keys.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.CMS.OrgSettings, as: Mixin
  alias KilnCMS.OrgSettings

  @ttl :timer.minutes(1)
  @global? !Application.compile_env(:kiln_cms, :strict_tenancy, true)

  defp key, do: {:org_settings_test, System.unique_integer([:positive])}
  defp org_id, do: Ash.UUID.generate()

  describe "resolve/2" do
    test "no row is build.(nil), and it IS cached — the read runs once" do
      key = key()
      test_pid = self()

      opts = [
        cache_key: key,
        ttl: @ttl,
        read: fn _org ->
          send(test_pid, :read)
          {:ok, []}
        end,
        build: fn nil -> :from_config end,
        fallback: fn -> :fallback end,
        label: "test"
      ]

      org = org_id()
      assert OrgSettings.resolve(org, opts) == :from_config
      assert OrgSettings.resolve(org, opts) == :from_config
      assert_received :read
      refute_received :read
    end

    test "a row is build.(row)" do
      opts = [
        cache_key: key(),
        ttl: @ttl,
        read: fn _org -> {:ok, [%{value: 42}]} end,
        build: fn %{value: v} -> {:built, v} end,
        fallback: fn -> :fallback end
      ]

      assert OrgSettings.resolve(org_id(), opts) == {:built, 42}
    end

    test "a read that returns {:error, _} degrades to the fallback, uncached, and logs" do
      key = key()
      calls = :counters.new(1, [])

      opts = [
        cache_key: key,
        ttl: @ttl,
        read: fn _org ->
          :counters.add(calls, 1, 1)
          {:error, :boom}
        end,
        build: fn _ -> :never end,
        fallback: fn -> :fallback end,
        label: "widget"
      ]

      org = org_id()

      log =
        capture_log(fn ->
          assert OrgSettings.resolve(org, opts) == :fallback
          assert OrgSettings.resolve(org, opts) == :fallback
        end)

      # Both calls read — nothing was cached for the failure — and the line
      # names the setting.
      assert :counters.get(calls, 1) == 2
      assert log =~ "widget lookup failed"
      assert log =~ ":boom"
    end

    test "a read that RAISES degrades the same way — a missing table mid-deploy is not a 500" do
      opts = [
        cache_key: key(),
        ttl: @ttl,
        read: fn _org -> raise Postgrex.Error, message: "relation does not exist" end,
        build: fn _ -> :never end,
        fallback: fn -> :fallback end,
        label: "widget"
      ]

      log = capture_log(fn -> assert OrgSettings.resolve(org_id(), opts) == :fallback end)
      assert log =~ "widget lookup failed"
      assert log =~ "relation does not exist"
    end

    test "the fallback is the caller's, not the operator config: whatever function is passed" do
      # #1077's lesson — Feeds degrades to summaries-only, not to a config that
      # might turn full content on. The mechanism must not assume.
      opts = [
        cache_key: key(),
        ttl: @ttl,
        read: fn _org -> {:error, :down} end,
        build: fn nil -> :operator_config end,
        fallback: fn -> :closed end
      ]

      capture_log(fn -> assert OrgSettings.resolve(org_id(), opts) == :closed end)
    end

    test "resolve_uncached/2 is the read-and-build half, nil on failure" do
      opts = [read: fn _ -> {:ok, [:row]} end, build: fn :row -> :built end]
      assert OrgSettings.resolve_uncached(org_id(), opts) == :built

      opts = [read: fn _ -> {:error, :x} end, build: fn _ -> :never end]
      capture_log(fn -> assert OrgSettings.resolve_uncached(org_id(), opts) == nil end)
    end
  end

  describe "the resource mixin" do
    # The nine the issue named. Discovered, not listed, by `Mixin.all/0`; this
    # pins that discovery finds all of them so a `use` line quietly removed
    # from one shows up here.
    @expected [
      KilnCMS.CMS.FeedSettings,
      KilnCMS.CMS.FormSpamSettings,
      KilnCMS.CMS.SiteBranding,
      KilnCMS.CMS.SiteCodeInjection,
      KilnCMS.CMS.SiteCompliance,
      KilnCMS.CMS.SiteEditorialSettings,
      KilnCMS.CMS.SiteEmbedSettings,
      KilnCMS.CMS.SiteLinkCheck,
      KilnCMS.Federation.SiteFederation
    ]

    test "every per-org settings resource is built on it" do
      assert Mixin.all() == @expected
    end

    test "no resource with a :one_per_org identity is hand-rolled — the tenth cannot skip the mixin" do
      # The `global?` line is what keeps one tenant's row out of another's read
      # and is emitted by the mixin; a resource that spells the identity by hand
      # is the shape that could omit it. So: anything shaped like one of these
      # must BE one of these.
      hand_rolled =
        [KilnCMS.CMS, KilnCMS.Federation, KilnCMS.Accounts, KilnCMS.Mail, KilnCMS.Billing]
        |> Enum.flat_map(fn domain ->
          case Code.ensure_loaded(domain) do
            {:module, _} -> Ash.Domain.Info.resources(domain)
            _ -> []
          end
        end)
        |> Enum.filter(fn resource ->
          Enum.any?(Ash.Resource.Info.identities(resource), &(&1.name == :one_per_org))
        end)
        |> Enum.reject(&function_exported?(&1, :__kiln_org_settings__, 0))

      assert hand_rolled == [],
             "these resources declare :one_per_org by hand — build them on KilnCMS.CMS.OrgSettings: #{inspect(hand_rolled)}"
    end

    test "each one carries the shared shape the mixin exists to guarantee" do
      for resource <- Mixin.all() do
        assert Ash.Resource.Info.multitenancy_strategy(resource) == :attribute, inspect(resource)
        assert Ash.Resource.Info.multitenancy_attribute(resource) == :org_id, inspect(resource)

        # `global?` follows `strict_tenancy` (test env: not strict → global).
        assert Ash.Resource.Info.multitenancy_global?(resource) == @global?, inspect(resource)

        org_id = Ash.Resource.Info.attribute(resource, :org_id)
        refute org_id.writable?, "#{inspect(resource)}: org_id must not be writable"
        refute org_id.public?, "#{inspect(resource)}: org_id must not be public"

        save = Ash.Resource.Info.action(resource, :save)

        assert save.type == :create and save.upsert? and save.upsert_identity == :one_per_org,
               "#{inspect(resource)}: :save must upsert on :one_per_org"

        assert Ash.Resource.Info.action(resource, :destroy).type == :destroy, inspect(resource)

        assert Ash.Resource.Info.relationship(resource, :organization).destination ==
                 KilnCMS.Accounts.Organization,
               inspect(resource)

        assert %{table: table, read: read} = resource.__kiln_org_settings__()
        assert AshPostgres.DataLayer.Info.table(resource) == table
        assert read in [:public, :editor, :admin]
      end
    end

    test "writes are OrgAdmin on every one, and the read tier is what each declared" do
      for resource <- Mixin.all() do
        policies = Ash.Policy.Info.policies(resource)

        write =
          Enum.find(policies, fn p ->
            match?([{Ash.Policy.Check.ActionType, opts}] when is_list(opts), p.condition) and
              :create in (p.condition |> hd() |> elem(1) |> Keyword.get(:type))
          end)

        assert write, "#{inspect(resource)}: no write policy"

        assert Enum.any?(write.policies, &match?({KilnCMS.CMS.Checks.OrgAdmin, _}, &1.check)),
               "#{inspect(resource)}: writes must be OrgAdmin"

        read =
          Enum.find(policies, fn p ->
            match?([{Ash.Policy.Check.ActionType, [type: [:read], access_type: _]}], p.condition)
          end)

        assert read, "#{inspect(resource)}: no read policy"

        expected_check =
          case resource.__kiln_org_settings__().read do
            :public -> Ash.Policy.Check.Static
            :editor -> KilnCMS.CMS.Checks.OrgEditor
            :admin -> KilnCMS.CMS.Checks.OrgAdmin
          end

        assert Enum.any?(read.policies, &match?({^expected_check, _}, &1.check)),
               "#{inspect(resource)}: read policy does not match its declared tier"
      end
    end
  end
end
