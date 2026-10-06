defmodule KilnCMS.Organize.TaggingTest do
  @moduledoc """
  Bulk tag review (#1596) and its budget bound. Every budget assertion reads
  the live `KilnCMS.LLM.Budget` counter, so a loop that "tries the next one
  anyway" — each refused Hammer charge still counts — fails here.
  """
  # async: false — swaps the global KilnCMS.Search env.
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrganizeFixtures

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.LLM.Budget
  alias KilnCMS.Organize.Tagging
  alias KilnCMS.Organize.Terms

  @minute :timer.minutes(1)
  @hour :timer.hours(1)

  defmodule RaisingEmbedder do
    @moduledoc false
    @behaviour KilnCMS.Search.Embedder
    @impl true
    def embed(_text), do: raise("the embedder must not be called with semantic search off")
  end

  setup do
    semantic_on!()
    org = org!()
    admin = user!(:admin)
    tags = for _ <- 1..3, do: tag!(org, admin)
    # The console fills the tag index before it offers a run; so do these.
    {:ok, %{remaining: 0}} = Terms.index_tag_vectors(org, admin)
    # That indexing charged the org bucket (3 tag names). Every org-counter
    # assertion below is relative to this.
    base = spent("org", org.id, @hour)
    assert base == 3
    %{org: org, admin: admin, editor: user!(:admin), tags: tags, base: base}
  end

  defp budget(per_user, per_org \\ 600, share \\ 0.5) do
    put_search_env(
      embedding_per_user_limit: {per_user, @minute},
      embedding_per_org_limit: {per_org, @hour},
      embedding_unattended_share: share
    )
  end

  # A never-published draft with `n` distinct, never-embedded blocks: `n`
  # real inferences to compute its centroid.
  defp draft(org, admin, n) do
    post!(org, admin, for(i <- 1..n, do: "draft passage #{i} #{uniq()}"), publish?: false)
  end

  defp selection(org, editor, docs) do
    ids = MapSet.new(docs, & &1.id)
    org |> Tagging.selection(editor) |> Enum.filter(&MapSet.member?(ids, &1.id)) |> Enum.reverse()
  end

  test "a published library costs nothing, even at a zero-room budget",
       %{org: org, admin: admin, editor: editor, base: base} do
    docs = for _ <- 1..3, do: post!(org, admin, "published passage #{uniq()}")
    budget(1, 1)

    run = Tagging.propose(org, editor, selection(org, editor, docs))

    assert run.stopped == nil
    assert run.spent == 0
    assert Enum.map(run.rows, & &1.status) == [:proposed, :proposed, :proposed]
    assert spent("user", editor.id, @minute) == 0
    assert spent("org", org.id, @hour) == base
  end

  test "stops BEFORE the document that would pass the run cap, then before the window",
       %{org: org, admin: admin, editor: editor} do
    budget(5)
    docs = [draft(org, admin, 2), draft(org, admin, 2), draft(org, admin, 2)]

    run = Tagging.propose(org, editor, selection(org, editor, docs))

    assert Enum.map(run.rows, &{&1.id, &1.status, &1.cost}) ==
             [{Enum.at(docs, 0).id, :proposed, 2}, {Enum.at(docs, 1).id, :proposed, 2}]

    assert run.stopped == :run_cap
    assert Enum.map(run.pending, & &1.id) == [Enum.at(docs, 2).id]
    assert run.spent == 4
    assert spent("user", editor.id, @minute) == 4

    # Continue in the same window: one unit of room, a two-unit document —
    # stopped before the call, so nothing is charged (a refused charge would
    # have pushed the counter to 6).
    again = Tagging.propose(org, editor, run.pending)
    assert again.rows == []
    assert {:rate_limited, _} = again.stopped
    assert Enum.map(again.pending, & &1.id) == [Enum.at(docs, 2).id]
    assert spent("user", editor.id, @minute) == 4
  end

  test "a document too large for any run is marked and skipped, never retried",
       %{org: org, admin: admin, editor: editor} do
    budget(5)
    docs = [draft(org, admin, 2), draft(org, admin, 8), draft(org, admin, 2)]

    run = Tagging.propose(org, editor, selection(org, editor, docs))

    assert Enum.map(run.rows, &{&1.status, &1.cost}) ==
             [{:proposed, 2}, {:too_large, 8}, {:proposed, 2}]

    assert run.stopped == nil
    assert run.pending == []
    assert spent("user", editor.id, @minute) == 4
  end

  test "unattended embedding switched off: a costed document stops the run with that reason",
       %{org: org, admin: admin, editor: editor, base: base} do
    budget(60, 600, 0.0)
    live = post!(org, admin, "published passage #{uniq()}")
    costly = draft(org, admin, 2)

    run = Tagging.propose(org, editor, selection(org, editor, [live, costly]))

    # The free one still ran: it never touches the budget.
    assert [%{id: id, status: :proposed}] = run.rows
    assert id == live.id
    assert run.stopped == :unattended_disabled
    assert Enum.map(run.pending, & &1.id) == [costly.id]
    assert spent("org", org.id, @hour) == base
  end

  test "automation already spent the background share: stopped, not charged",
       %{org: org, admin: admin, editor: editor} do
    # Org window 10, share 0.5: unattended callers stop at 5. Setup spent 3;
    # an automation rule spends the other 2.
    budget(60, 10, 0.5)

    :ok =
      Budget.check(
        "search_embedding",
        org.id,
        "automation:rule",
        KilnCMS.Search.embedding_budget_limits(true, 2)
      )

    assert spent("org", org.id, @hour) == 5

    run = Tagging.propose(org, editor, selection(org, editor, [draft(org, admin, 2)]))

    assert {:rate_limited, _} = run.stopped
    assert run.rows == []
    assert spent("org", org.id, @hour) == 5
    assert spent("user", editor.id, @minute) == 0
  end

  test "the run charges unattended: it can never reach the interactive reserve",
       %{org: org, admin: admin, editor: editor} do
    # Org window 14, share 0.5: unattended callers stop at 7. Setup spent 3,
    # so the run has 4 units of background room.
    budget(60, 14, 0.5)
    docs = [draft(org, admin, 2), draft(org, admin, 2), draft(org, admin, 2)]

    run = Tagging.propose(org, editor, selection(org, editor, docs))

    # Two fit under the ceiling; the third would cross it, and is not tried.
    assert length(run.rows) == 2
    assert {:rate_limited, _} = run.stopped
    assert spent("org", org.id, @hour) == 7
    # The other 7 — the interactive half — are untouched.
  end

  test "a tag held in a pending working copy is not proposed again",
       %{org: org, admin: admin, editor: editor, tags: [a, b, c]} do
    live = post!(org, admin, "held passage #{uniq()}", tag_ids: [b.id])

    {:ok, _} =
      ContentTypes.save_working_copy("post", live, %{fields: %{"add_tag_ids" => [a.id]}},
        actor: admin,
        tenant: org
      )

    [row] = Tagging.propose(org, editor, selection(org, editor, [live])).rows
    offered = MapSet.new(row.suggestions, & &1.term.id)

    assert offered == MapSet.new([c.id])
  end

  describe "apply/4" do
    test "only proposed ids are applied; a draft saves, a live document holds",
         %{org: org, admin: admin, editor: editor, tags: [a, _b, _c]} do
      other_org_tag = tag!(org!(), admin)
      draft = post!(org, admin, "apply passage #{uniq()}", publish?: false)
      live = post!(org, admin, "apply live #{uniq()}")

      run = Tagging.propose(org, editor, selection(org, editor, [draft, live]))
      [draft_row, live_row] = run.rows
      assert a.id in Enum.map(draft_row.suggestions, & &1.term.id)

      # A forged id rides along and is dropped; the proposed one lands.
      assert {:ok, :saved} = Tagging.apply(org, editor, draft_row, [a.id, other_org_tag.id])
      tags = CMS.get_post!(draft.id, actor: admin, tenant: org, load: [:tags]).tags
      assert Enum.map(tags, & &1.id) == [a.id]

      assert {:error, :nothing_ticked} = Tagging.apply(org, editor, draft_row, [other_org_tag.id])

      assert {:ok, :working_copy} = Tagging.apply(org, editor, live_row, [a.id])
      reloaded = CMS.get_post!(live.id, actor: admin, tenant: org, load: [:tags])
      assert reloaded.tags == []
      assert Terms.applied_tag_ids(reloaded) == [a.id]
    end
  end

  test "semantic off: nothing selected, nothing proposed, nothing charged",
       %{org: org, admin: admin, editor: editor} do
    doc = draft(org, admin, 2)
    put_search_env(semantic: false, embedder: RaisingEmbedder)

    assert Tagging.selection(org, editor) == []

    assert Tagging.propose(org, editor, [%{id: doc.id, type: "post"}]) ==
             %{rows: [], stopped: nil, pending: [], spent: 0}

    assert spent("user", editor.id, @minute) == 0
  end
end
