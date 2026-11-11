defmodule KilnCMS.Search.SynonymsTest do
  @moduledoc """
  Search synonyms (A7): the matcher (`Synonyms.expand/2`), the
  `SearchSynonym` resource's normalization, validation and policies, and the
  `:synonym` leg of `Search.hybrid/3` — an alternate wording finds what the
  user's words did not, and ranks below the same match on the user's words.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Search
  alias KilnCMS.Search.Synonyms

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "syn-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp uniq, do: System.unique_integer([:positive])

  defp published_page(title, actor) do
    %{title: title, slug: "syn-#{uniq()}"}
    |> CMS.create_page!(actor: actor)
    |> CMS.publish_page!(%{}, actor: actor)
  end

  describe "expand/2" do
    @group Synonyms.rule_mappings(%{kind: :group, terms: ["reishi", "ling zhi", "ganoderma"]})
    @one_way Synonyms.rule_mappings(%{
               kind: :one_way,
               terms: ["tcm"],
               expands_to: ["traditional chinese medicine"]
             })

    test "a group term is replaced by each of the others, in place" do
      assert Synonyms.expand("Reishi tea", @group) == ["ling zhi tea", "ganoderma tea"]
    end

    test "a multi-word term matches as a phrase, and maps back" do
      assert Synonyms.expand("ling  zhi benefits", @group) ==
               ["reishi benefits", "ganoderma benefits"]

      assert Synonyms.expand("ling benefits", @group) == []
    end

    test "a one-way rule expands only forward" do
      assert Synonyms.expand("tcm herbs", @one_way) == ["traditional chinese medicine herbs"]
      assert Synonyms.expand("traditional chinese medicine", @one_way) == []
    end

    test "terms match whole words only" do
      assert Synonyms.expand("reishis", @group) == []
      assert Synonyms.expand("tcmx", @one_way) == []
    end

    test "an alternate the query already names is skipped" do
      assert Synonyms.expand("reishi ling zhi", @group) == [
               "ganoderma ling zhi",
               "reishi ganoderma"
             ]
    end

    test "a rule's text is never read as a regex replacement" do
      mappings = Synonyms.rule_mappings(%{kind: :group, terms: ["a.b", ~S"x\0y"]})
      assert Synonyms.expand("a.b", mappings) == [~S"x\0y"]
      assert Synonyms.expand("axb", mappings) == []
    end

    test "at most max_alternates/0 are returned" do
      terms = for i <- 1..10, do: "t#{i}"
      mappings = Synonyms.rule_mappings(%{kind: :group, terms: terms})
      assert length(Synonyms.expand("t1", mappings)) == Synonyms.max_alternates()
    end
  end

  describe "SearchSynonym" do
    test "terms are stored normalized, and a group drops one-way targets" do
      rule =
        CMS.create_search_synonym!(
          %{kind: :group, terms: [" Reishi ", "LING   zhi", "reishi", ""], expands_to: ["x"]},
          actor: user(:editor)
        )

      assert rule.terms == ["reishi", "ling zhi"]
      assert rule.expands_to == []
    end

    test "a rule that relates nothing is refused" do
      editor = user(:editor)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_search_synonym(%{kind: :group, terms: ["reishi", "Reishi"]},
                 actor: editor
               )

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_search_synonym(%{kind: :one_way, terms: ["tcm"]}, actor: editor)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_search_synonym(
                 %{kind: :one_way, terms: ["tcm"], expands_to: ["TCM"]},
                 actor: editor
               )
    end

    test "editors write and turn off rules; only an admin deletes one" do
      editor = user(:editor)
      rule = CMS.create_search_synonym!(%{terms: ["a#{uniq()}", "b#{uniq()}"]}, actor: editor)

      rule = CMS.update_search_synonym!(rule, %{enabled: false}, actor: editor)
      refute rule.enabled

      refute CMS.can_destroy_search_synonym?(editor, rule)
      assert {:error, %Ash.Error.Forbidden{}} = CMS.destroy_search_synonym(rule, actor: editor)

      assert :ok = CMS.destroy_search_synonym(rule, actor: user(:admin))
    end

    test "viewers and anonymous callers can neither read nor write rules" do
      CMS.create_search_synonym!(%{terms: ["a#{uniq()}", "b#{uniq()}"]}, actor: user(:editor))

      for actor <- [user(:viewer), nil] do
        assert CMS.list_search_synonyms!(actor: actor) == []

        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.create_search_synonym(%{terms: ["c", "d"]}, actor: actor)
      end
    end

    test "only enabled rules apply" do
      editor = user(:editor)
      term = "qwyx#{uniq()}"
      rule = CMS.create_search_synonym!(%{terms: [term, "zorb plim"]}, actor: editor)

      assert Synonyms.alternates(term, nil) == ["zorb plim"]

      CMS.update_search_synonym!(rule, %{enabled: false}, actor: editor)
      assert Synonyms.alternates(term, nil) == []
    end

    test "a write busts the site's cached rules" do
      org_id = KilnCMS.Accounts.default_org_id()
      key = KilnCMS.Cache.search_synonyms_key(org_id)
      KilnCMS.Cache.fetch(key, :timer.minutes(5), fn -> [{"stale", ["x"]}] end)

      CMS.create_search_synonym!(%{terms: ["a#{uniq()}", "b#{uniq()}"]}, actor: user(:editor))

      assert Cachex.get(KilnCMS.Cache.cache_name(), key) == {:ok, nil}
    end
  end

  describe "Search.hybrid/3" do
    test "an alternate wording finds a record the query's own words do not" do
      admin = user(:admin)
      n = uniq()
      page = published_page("Zorb#{n} Plim Field Notes", admin)
      CMS.create_search_synonym!(%{terms: ["qwyx#{n}", "zorb#{n} plim"]}, actor: admin)

      assert Search.hybrid(:page, "qwyx#{n}", synonyms: []) == []

      assert [hit] = Search.hybrid(:page, "qwyx#{n}")
      assert hit.id == page.id
      assert :synonym in Search.hit_legs(hit)
    end

    test "explain reports the synonym leg once, with every alternate list's contribution" do
      admin = user(:admin)
      n = uniq()
      # The title names the alternate outright, so both its keyword and title
      # lists return the page: two `:synonym` lists, one leg.
      published_page("Zorb#{n}", admin)
      CMS.create_search_synonym!(%{terms: ["qwyx#{n}", "zorb#{n}"]}, actor: admin)

      assert [hit] = Search.hybrid(:page, "qwyx#{n}", explain: true)
      assert Search.hit_legs(hit) == [:synonym]

      %{legs: legs} = Search.hit_explain(hit)
      assert Map.keys(legs) == [:synonym]
      assert_in_delta legs.synonym.contribution, Search.hit_score(hit), 1.0e-9
    end

    test "a match on the user's words outranks the same match on an alternate" do
      admin = user(:admin)
      n = uniq()
      alias_page = published_page("Zorb#{n} Plover#{n}", admin)
      own_page = published_page("Qwyx#{n} Plover#{n}", admin)
      CMS.create_search_synonym!(%{terms: ["qwyx#{n}", "zorb#{n}"]}, actor: admin)

      assert [first, second] = Search.hybrid(:page, "qwyx#{n} plover#{n}")
      assert first.id == own_page.id
      assert second.id == alias_page.id
      refute :synonym in Search.hit_legs(first)
      assert :synonym in Search.hit_legs(second)
      assert Search.hit_score(first) > Search.hit_score(second)
    end

    test "global/2 reads the rules once and hands them to every section" do
      admin = user(:admin)
      n = uniq()
      page = published_page("Zorb#{n} Page", admin)

      post =
        %{title: "Zorb#{n} Post", slug: "syn-#{uniq()}"}
        |> CMS.create_post!(actor: admin)
        |> CMS.publish_post!(%{}, actor: admin)

      CMS.create_search_synonym!(
        %{kind: :one_way, terms: ["qwyx#{n}"], expands_to: ["zorb#{n}"]},
        actor: admin
      )

      # Through `global_report/2`, so a sweep the query budget cut short says
      # so in the failure rather than reading as a missing synonym (#2337).
      report = Search.global_report("qwyx#{n}", sections: [:pages, :posts])
      assert report.partial == %{}, "the query budget cut the sweep: #{inspect(report.partial)}"
      assert Enum.map(report.sections.pages, & &1.id) == [page.id]
      assert Enum.map(report.sections.posts, & &1.id) == [post.id]
    end
  end
end
