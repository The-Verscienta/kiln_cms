defmodule KilnCMS.Search.RelatedTagBudgetTest do
  @moduledoc """
  `Related.suggest_tags/2` and `suggest_tags_partial/2` against a taxonomy
  larger than the room left in the caller's embedding window.

  A Hammer fixed window refuses a charge larger than its room **and still
  counts it** (it increments before it compares), and `suggest_tags/2` used to
  charge every never-indexed tag name in one charge. So an org with more than
  `embedding_per_user_limit/0` (60) unindexed tags could never be ranked, and
  each attempt added the whole count to the editor's bucket — starving their
  near-duplicate and link suggestions for the rest of the window. Every test
  here asserts the exact counters, because the counter is the defect.

  A "next window" without sleeping: Hammer keys a bucket on
  `div(now, window_ms)`, so a per-user window of `@minute + n` is a fresh one.
  """
  # async: false — swaps the global KilnCMS.Search env (stub embedder).
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrganizeFixtures

  alias KilnCMS.LLM.Budget
  alias KilnCMS.Search
  alias KilnCMS.Search.Related

  @minute :timer.minutes(1)
  @hour :timer.hours(1)

  defmodule RaisingEmbedder do
    @moduledoc false
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(_text), do: raise("the embedder must not be called with semantic search off")
  end

  defmodule PickyEmbedder do
    @moduledoc false
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(text) do
      if String.contains?(text, "unembeddable"),
        do: {:error, :no_vector},
        else: KilnCMS.StubEmbedder.embed(text)
    end
  end

  setup do
    semantic_on!()
    org = org!()
    admin = user!(:admin)
    # Published and indexed, so its centroid is stored and free: every unit
    # counted below is a tag name.
    post = post!(org, admin, "a passage about tag budgets #{uniq()}")
    %{org: org, admin: admin, editor: user!(:admin), post: post}
  end

  defp window(per_user_window_ms) do
    put_search_env(
      embedding_per_user_limit: {60, per_user_window_ms},
      embedding_per_org_limit: {600, @hour}
    )
  end

  defp tags!(org, admin, n), do: for(_ <- 1..n, do: tag!(org, admin))

  defp reload(post, org, admin),
    do: KilnCMS.CMS.get_post!(post.id, actor: admin, tenant: org, load: [:tags])

  defp opts(editor), do: [actor: editor, user_id: editor.id]

  describe "suggest_tags/2 — the strict path" do
    test "a set larger than the window is refused WITHOUT being counted",
         %{org: org, admin: admin, editor: editor, post: post} do
      window(@minute)
      tags!(org, admin, 70)

      assert {:error, {:rate_limited, _}} =
               Related.suggest_tags(reload(post, org, admin), opts(editor))

      # Before the fix: 70 — the refused charge counted, and the editor's
      # whole window was gone.
      assert spent("user", editor.id, @minute) == 0
      assert spent("org", org.id, @hour) == 0
      # Nothing embedded on refusal.
      assert length(Related.missing_tag_vectors(org.id, KilnCMS.CMS.list_tags!(tenant: org))) ==
               70
    end

    test "a set that fits is still one charge for the whole set",
         %{org: org, admin: admin, editor: editor, post: post} do
      window(@minute)
      tags!(org, admin, 10)

      suggestions = Related.suggest_tags(reload(post, org, admin), opts(editor))

      assert is_list(suggestions) and suggestions != []
      assert spent("user", editor.id, @minute) == 10
      assert spent("org", org.id, @hour) == 10
    end

    test "unattended share 0: :unattended_disabled, and nothing counted",
         %{org: org, admin: admin, post: post} do
      window(@minute)
      put_search_env(embedding_unattended_share: 0.0)
      tags!(org, admin, 5)
      bot = "automation:#{uniq()}"

      assert {:error, :unattended_disabled} =
               Related.suggest_tags(reload(post, org, admin), user_id: bot, unattended?: true)

      # Before the fix the user bucket was hit (5) on the way to the reserve's
      # refusal.
      assert spent("user", bot, @minute) == 0
      assert spent("org", org.id, @hour) == 0
    end
  end

  describe "suggest_tags_partial/2 — the editor panel" do
    test "a 70-tag org indexes 60, ranks them, and reopening in the window charges nothing",
         %{org: org, admin: admin, editor: editor, post: post} do
      window(@minute)
      tags!(org, admin, 70)
      post = reload(post, org, admin)

      assert {:ok, %{suggestions: [_ | _], unindexed: 10, failed: []}} =
               Related.suggest_tags_partial(post, opts(editor))

      assert spent("user", editor.id, @minute) == 60
      assert spent("org", org.id, @hour) == 60

      # No room left: ranks what is indexed, charges 0.
      assert {:ok, %{suggestions: [_ | _], unindexed: 10}} =
               Related.suggest_tags_partial(post, opts(editor))

      assert spent("user", editor.id, @minute) == 60
      assert spent("org", org.id, @hour) == 60
    end

    test "a partly spent editor indexes exactly the room left",
         %{org: org, admin: admin, editor: editor, post: post} do
      window(@minute)
      tags!(org, admin, 20)

      :ok =
        Budget.check(
          "search_embedding",
          org.id,
          editor.id,
          Search.embedding_budget_limits(false, 55)
        )

      assert {:ok, %{unindexed: 15}} =
               Related.suggest_tags_partial(reload(post, org, admin), opts(editor))

      assert spent("user", editor.id, @minute) == 60
      assert spent("org", org.id, @hour) == 60
    end

    test "150 tags converge over successive windows: 60, 60, 30, then 0",
         %{org: org, admin: admin, editor: editor, post: post} do
      tags!(org, admin, 150)
      post = reload(post, org, admin)

      for {n, charged, unindexed} <- [{0, 60, 90}, {1, 60, 30}, {2, 30, 0}, {3, 0, 0}] do
        window(@minute + n)

        assert {:ok, %{unindexed: ^unindexed}} = Related.suggest_tags_partial(post, opts(editor))
        assert spent("user", editor.id, @minute + n) == charged
      end

      assert spent("org", org.id, @hour) == 150
    end

    test "a stale (pre-rename) vector is never ranked",
         %{org: org, admin: admin, editor: editor, post: post} do
      window(@minute)
      [tag] = tags!(org, admin, 1)
      post = reload(post, org, admin)

      assert {:ok, %{suggestions: [%{tag: %{id: id}}]}} =
               Related.suggest_tags_partial(post, opts(editor))

      assert id == tag.id

      KilnCMS.CMS.update_tag!(tag, %{name: "renamed #{uniq()}"}, actor: admin, tenant: org)

      # Spend the rest of the window: the new name cannot be embedded now.
      :ok =
        Budget.check(
          "search_embedding",
          org.id,
          editor.id,
          Search.embedding_budget_limits(false, 59)
        )

      assert {:ok, %{suggestions: [], unindexed: 1}} =
               Related.suggest_tags_partial(post, opts(editor))
    end

    test "a name the embedder cannot answer for is reported, and :exclude moves past it",
         %{org: org, admin: admin, editor: editor, post: post} do
      put_search_env(
        embedder: PickyEmbedder,
        embedding_per_user_limit: {1, @minute},
        embedding_per_org_limit: {600, @hour}
      )

      bad = tag!(org, admin, "aaa unembeddable #{uniq()}")
      good = tag!(org, admin, "bbb fine #{uniq()}")
      post = reload(post, org, admin)

      assert {:ok, %{suggestions: [], unindexed: 1, failed: [failed_id]}} =
               Related.suggest_tags_partial(post, opts(editor))

      assert failed_id == bad.id

      put_search_env(embedding_per_user_limit: {1, @minute + 1})

      assert {:ok, %{suggestions: [%{tag: %{id: good_id}}], unindexed: 0, failed: []}} =
               Related.suggest_tags_partial(post, opts(editor) ++ [exclude: [bad.id]])

      assert good_id == good.id
    end

    test "semantic search off: a no-op that never touches the budget or the embedder",
         %{org: org, admin: admin, editor: editor, post: post} do
      tags!(org, admin, 70)
      put_search_env(semantic: false, embedder: RaisingEmbedder)

      assert {:ok, %{suggestions: [], unindexed: 0, failed: []}} =
               Related.suggest_tags_partial(reload(post, org, admin), opts(editor))

      assert spent("user", editor.id, @minute) == 0
      assert spent("org", org.id, @hour) == 0
    end
  end
end
