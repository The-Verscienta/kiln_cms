defmodule KilnCMS.MultitenancyAnalyticsNewsletterTest do
  @moduledoc """
  Tenant isolation for the analytics, newsletter, history, and automation
  resources (epic #336, PR 4d — the final resource sweep).

  Proves the `:attribute` axis holds across the last cluster: per-site view /
  search counters (even for a shared content id / query), a newsletter
  subscriber per site, automation rules that only match their own site, and a
  history event stamped with its document's org.

  Not async: reads span the tables and the shared sandbox is required. Orgs are
  seeded via `Ash.Seed` to bypass the `multitenancy_enabled` create guard.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Analytics
  alias KilnCMS.Automation
  alias KilnCMS.History
  alias KilnCMS.Newsletter

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "mtan-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org(name) do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: name,
      slug: "#{name}-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  setup do
    %{a: org("orga"), b: org("orgb"), actor: admin()}
  end

  describe "ContentView counters are per-site" do
    test "the same content id counts independently per org", %{a: a, b: b} do
      id = Ash.UUID.generate()

      va = Analytics.record_view!("page", id, authorize?: false, tenant: a)
      # Two views in B, one in A → separate counters keyed by org.
      Analytics.record_view!("page", id, authorize?: false, tenant: b)
      vb = Analytics.record_view!("page", id, authorize?: false, tenant: b)

      assert va.org_id == a.id
      assert vb.org_id == b.id
      assert va.views == 1
      assert vb.views == 2
    end
  end

  describe "SearchQuery counters are per-site" do
    test "a recorded query is scoped to its org", %{a: a, b: b, actor: actor} do
      q = "zzq#{System.unique_integer([:positive])}"

      Analytics.record_search!(%{query: q, locale: "en", result_count: 3},
        authorize?: false,
        tenant: a
      )

      a_queries = Analytics.top_searches!(actor: actor, tenant: a) |> Enum.map(& &1.query)
      assert q in a_queries

      b_queries = Analytics.top_searches!(actor: actor, tenant: b) |> Enum.map(& &1.query)
      refute q in b_queries
    end
  end

  describe "Newsletter subscribers are per-site" do
    test "the same email can subscribe to two sites independently", %{a: a, b: b} do
      email = "sub-#{System.unique_integer([:positive])}@example.com"

      sa = Newsletter.subscribe!(%{email: email}, authorize?: false, tenant: a)
      sb = Newsletter.subscribe!(%{email: email}, authorize?: false, tenant: b)

      assert sa.org_id == a.id
      assert sb.org_id == b.id
      refute sa.id == sb.id
    end
  end

  describe "Automation rules match only their own site" do
    test "rules_for returns only the reading org's rules", %{a: a, b: b, actor: actor} do
      ra =
        Automation.create_rule!(
          %{name: "A rule", trigger_event: :published, action: :broadcast, config: %{}},
          actor: actor,
          tenant: a
        )

      {:ok, a_rules} = Automation.rules_for(:published, "post", authorize?: false, tenant: a)
      assert Enum.any?(a_rules, &(&1.id == ra.id))

      {:ok, b_rules} = Automation.rules_for(:published, "post", authorize?: false, tenant: b)
      refute Enum.any?(b_rules, &(&1.id == ra.id))
    end
  end

  describe "History events carry the document's org" do
    test "an appended event is stamped with the given org", %{a: a} do
      id = Ash.UUID.generate()

      {:ok, event} =
        History.record(:page, id, :block_added, %{"block" => %{}, "index" => 0}, org_id: a.id)

      assert event.org_id == a.id
    end
  end
end
