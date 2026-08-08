defmodule KilnCMS.CMS.FragmentsTest do
  @moduledoc """
  Reusable content fragments (#479): inlining at fire time, the fail-closed
  visibility rules, cycle and depth bounds, and the reference edge that makes
  editing a fragment re-fire everything embedding it.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Fragments
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Firing.Engine

  require Ash.Query

  defp uniq, do: System.unique_integer([:positive])
  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp page(attrs) do
    Ash.Seed.seed!(
      KilnCMS.CMS.Page,
      Map.merge(%{title: "P", slug: "fr-#{uniq()}", state: :published}, attrs)
    )
  end

  defp fragment_block(record, type \\ "page") do
    %{"_type" => "fragment", "ref" => %{"type" => type, "id" => record.id}}
  end

  defp expand(blocks, opts \\ []) do
    blocks |> TypedBlocks.to_typed() |> Fragments.expand(org_id(), opts)
  end

  defp labels(typed) do
    Enum.map(typed, fn
      %{text: text} -> text
      %{_type: type} -> type
    end)
  end

  test "a fragment is replaced by its target's blocks, in place" do
    shared = page(%{blocks: [%{"_type" => "heading", "text" => "Shared"}]})

    expanded =
      expand([
        %{"_type" => "heading", "text" => "Before"},
        fragment_block(shared),
        %{"_type" => "heading", "text" => "After"}
      ])

    assert labels(expanded) == ["Before", "Shared", "After"]
  end

  test "a tree with no fragments comes back untouched" do
    blocks = [%{"_type" => "heading", "text" => "Only"}]

    assert labels(expand(blocks)) == ["Only"]
  end

  test "the same fragment twice on a page renders twice" do
    shared = page(%{blocks: [%{"_type" => "heading", "text" => "CTA"}]})

    expanded = expand([fragment_block(shared), fragment_block(shared)])

    assert labels(expanded) == ["CTA", "CTA"]
  end

  test "fragments nest" do
    inner = page(%{blocks: [%{"_type" => "heading", "text" => "Inner"}]})
    outer = page(%{blocks: [fragment_block(inner)]})

    assert labels(expand([fragment_block(outer)])) == ["Inner"]
  end

  test "a fragment inside a column stays inside that column" do
    shared = page(%{blocks: [%{"_type" => "heading", "text" => "In column"}]})

    [columns] =
      expand([
        %{"_type" => "columns", "columns" => [%{"blocks" => [fragment_block(shared)]}]}
      ])

    assert [%{"blocks" => [child]}] = columns.columns
    assert child["_type"] == "heading"
    assert child["text"] == "In column"
  end

  describe "failing closed" do
    test "an unpublished target renders nothing" do
      draft = page(%{state: :draft, blocks: [%{"_type" => "heading", "text" => "Secret"}]})

      assert expand([fragment_block(draft)]) == []
    end

    test "an archived target renders nothing" do
      archived = page(%{state: :archived, blocks: [%{"_type" => "heading", "text" => "Old"}]})

      assert expand([fragment_block(archived)]) == []
    end

    # The target read runs `authorize?: false`, so its filter is the entire
    # security boundary — it has to gate the audience axis, not just state.
    test "a gated target renders nothing for a public reader, and inlines for a member" do
      gated =
        page(%{audience: :member, blocks: [%{"_type" => "heading", "text" => "Members only"}]})

      assert expand([fragment_block(gated)]) == []

      assert labels(expand([fragment_block(gated)], audiences: [:member])) == ["Members only"]
    end

    # `:audiences` widens on top of `:public`, exactly as `public_by_slug`
    # treats it — an anonymous reader arrives with `[]`, and reading that as
    # "nothing matches" would blank every fragment on the public site.
    test "an explicit empty audience list still sees public content" do
      shared = page(%{blocks: [%{"_type" => "heading", "text" => "Public"}]})

      assert labels(expand([fragment_block(shared)], audiences: [])) == ["Public"]
    end

    # `:reference` is a bare map with no constraints and the editor only
    # normalizes a *binary* `ref`, so a crafted nested-map payload stores
    # verbatim. An unguarded `to_string/1` on it would raise on every anonymous
    # render of the page from then on — a persistent 500 an editor can cause.
    test "a malformed reference is a miss, not a crash" do
      for ref <- [
            %{"type" => %{"x" => 1}, "id" => Ash.UUID.generate()},
            %{"type" => "page", "id" => ["list"]},
            %{"type" => "page", "id" => 42},
            %{"type" => "page"},
            %{},
            "not a map"
          ] do
        assert expand([%{"_type" => "fragment", "ref" => ref}]) == []
      end
    end

    test "a missing target, an unknown type and a junk id all render nothing" do
      assert expand([
               %{"_type" => "fragment", "ref" => %{"type" => "page", "id" => Ash.UUID.generate()}}
             ]) ==
               []

      published = page(%{blocks: [%{"_type" => "heading", "text" => "Live"}]})

      assert expand([fragment_block(published, "no-such-type")]) == []

      assert expand([%{"_type" => "fragment", "ref" => %{"type" => "page", "id" => "junk"}}]) ==
               []

      assert expand([%{"_type" => "fragment", "ref" => nil}]) == []
    end
  end

  describe "cycles and depth" do
    # A cycle needs two documents pointing at each other, and either write is
    # individually fine — so it can only be caught here.
    test "a two-document cycle terminates, inlining each body once" do
      a = page(%{blocks: [%{"_type" => "heading", "text" => "A"}]})
      b = page(%{blocks: [%{"_type" => "heading", "text" => "B"}, fragment_block(a)]})

      a = CMS.update_page!(a, %{}, authorize?: false)

      Ash.Seed.update!(a, %{
        blocks: [%{"_type" => "heading", "text" => "A"}, fragment_block(b)]
      })

      # Embedding A: A's body, then B's body, then B's fragment back to A — which
      # is already on this branch and is skipped.
      assert labels(expand([fragment_block(a)])) == ["A", "B"]
    end

    test "a self-reference renders the body once, not forever" do
      page = page(%{blocks: [%{"_type" => "heading", "text" => "Self"}]})
      Ash.Seed.update!(page, %{blocks: [%{"_type" => "heading", "text" => "Self"}]})

      Ash.Seed.update!(page, %{
        blocks: [%{"_type" => "heading", "text" => "Self"}, fragment_block(page)]
      })

      assert labels(expand([fragment_block(page)])) == ["Self"]
    end

    # Depth bounds depth, not breadth: without a memo a host with B refs whose
    # targets each have B more costs B + B² + B³ reads on an anonymous render.
    test "the same target is read once however many times it appears" do
      shared = page(%{blocks: [%{"_type" => "heading", "text" => "Once"}]})

      blocks = for _ <- 1..20, do: fragment_block(shared)

      assert labels(expand(blocks)) == List.duplicate("Once", 20)
    end

    test "a chain longer than max_depth stops" do
      deepest = page(%{blocks: [%{"_type" => "heading", "text" => "Bottom"}]})

      top =
        Enum.reduce(1..Fragments.max_depth(), deepest, fn i, below ->
          page(%{blocks: [%{"_type" => "heading", "text" => "L#{i}"}, fragment_block(below)]})
        end)

      expanded = labels(expand([fragment_block(top)]))

      # Every level's own content is present; the one past the cap is not.
      assert "L#{Fragments.max_depth()}" in expanded
      refute "Bottom" in expanded
    end
  end

  describe "firing" do
    test "the fired artifact carries the target's body, not the reference" do
      shared = page(%{blocks: [%{"_type" => "heading", "text" => "Inlined"}]})
      host = page(%{title: "Host", blocks: [fragment_block(shared)]})

      {:ok, artifacts} = Engine.fire(host, mode: :preview)

      assert artifacts[:web]["html"] =~ "Inlined"
      assert [%{"_type" => "heading", "text" => "Inlined"}] = artifacts[:json]["blocks"]
    end

    # The edge is what makes publishing a fragment re-fire its referrers, and it
    # is extracted from the RAW tree — expanding before the rebuild would delete
    # it and silently turn the feature into a one-shot copy.
    test "firing records a reference edge to the target" do
      shared = page(%{blocks: [%{"_type" => "heading", "text" => "Inlined"}]})
      host = page(%{title: "Host", blocks: [fragment_block(shared)]})

      {:ok, _} = Engine.fire(host)

      edges =
        KilnCMS.Firing.ReferenceEdge
        |> Ash.Query.filter(from_id == ^host.id)
        |> Ash.read!(authorize?: false, tenant: org_id())

      assert Enum.any?(edges, &(&1.to_type == :page and &1.to_id == shared.id))
    end

    test "a fragment whose target is a draft fires nothing for it" do
      draft = page(%{state: :draft, blocks: [%{"_type" => "heading", "text" => "Secret"}]})
      host = page(%{title: "Host", blocks: [fragment_block(draft)]})

      {:ok, artifacts} = Engine.fire(host, mode: :preview)

      refute artifacts[:web]["html"] =~ "Secret"
    end

    # An artifact is keyed to its host, and every consumer of one — the headless
    # artifact endpoint, the feeds, static export, the newsletter — resolves that
    # host through a `:public`-only filter and then serves the body verbatim. An
    # artifact that carried content stricter than its host would hand a gated
    # body to anonymous callers on all four.
    test "a public host's artifact never carries a gated fragment" do
      gated = page(%{audience: :member, blocks: [%{"_type" => "heading", "text" => "Members"}]})
      host = page(%{title: "Host", blocks: [fragment_block(gated)]})

      {:ok, artifacts} = Engine.fire(host, mode: :preview)

      refute artifacts[:web]["html"] =~ "Members"
    end

    test "a gated host's artifact does carry a fragment gated the same way" do
      gated = page(%{audience: :member, blocks: [%{"_type" => "heading", "text" => "Members"}]})

      host =
        page(%{title: "Host", audience: :member, blocks: [fragment_block(gated)]})

      {:ok, artifacts} = Engine.fire(host, mode: :preview)

      assert artifacts[:web]["html"] =~ "Members"
    end

    # Seeding the ancestry with the host is what stops this: the guard would
    # otherwise only catch the loop one level down, after the body was inlined.
    test "a document embedding itself does not duplicate its own body" do
      host = page(%{blocks: [%{"_type" => "heading", "text" => "Own"}]})

      Ash.Seed.update!(host, %{
        blocks: [%{"_type" => "heading", "text" => "Own"}, fragment_block(host)]
      })

      host = CMS.get_page!(host.id, authorize?: false)
      {:ok, artifacts} = Engine.fire(host, mode: :preview)

      assert artifacts[:json]["blocks"] |> Enum.count(&(&1["text"] == "Own")) == 1
    end
  end

  describe "the node budget (#917)" do
    # The blowup the fetch budget did not bound: the memo returns a cached
    # target without spending a fetch, and inlining re-runs the expansion over
    # that target's whole tree at every occurrence — so the EMITTED tree grows
    # as B^(depth+1) while `max_fetches/0` counts only distinct targets.
    #
    # Three chained pages holding `b` fragment blocks each cost 3 fetches and
    # used to emit b³ blocks. With b=40 that is 64,000 from one anonymous GET;
    # the issue's b=200 is eight million.
    defp chain(breadth) do
      leaf = page(%{blocks: [%{"_type" => "heading", "text" => "Leaf"}]})
      mid = page(%{blocks: List.duplicate(fragment_block(leaf), breadth)})
      top = page(%{blocks: List.duplicate(fragment_block(mid), breadth)})
      top
    end

    test "a wide chain is capped instead of exploding" do
      breadth = 40
      top = chain(breadth)

      expanded = expand(List.duplicate(fragment_block(top), breadth))

      # Unbounded this is breadth³ = 64,000 (and the host multiplies it again).
      assert length(expanded) <= Fragments.max_nodes()
      refute length(expanded) >= breadth * breadth * breadth
    end

    test "the cap does not disturb an ordinary page" do
      # The bound must be invisible to real content: a handful of fragments,
      # nested, well under the ceiling.
      inner = page(%{blocks: [%{"_type" => "heading", "text" => "Inner"}]})
      outer = page(%{blocks: [fragment_block(inner), %{"_type" => "heading", "text" => "Own"}]})

      expanded =
        expand([
          %{"_type" => "heading", "text" => "Before"},
          fragment_block(outer),
          fragment_block(inner),
          %{"_type" => "heading", "text" => "After"}
        ])

      assert labels(expanded) == ["Before", "Inner", "Own", "Inner", "After"]
    end

    test "only inlined blocks are charged, so a long page is never truncated" do
      # The host's OWN blocks must not be charged, however many there are —
      # charging them would turn the budget into a page-length limit.
      #
      # There has to be a fragment in the list, or `expand/3` returns at the
      # `any_fragment?/1` early exit and never reaches the charging code, which
      # makes the assertion true for the wrong reason.
      shared = page(%{blocks: [%{"_type" => "heading", "text" => "Shared"}]})

      long =
        for i <- 1..(Fragments.max_nodes() + 50), do: %{"_type" => "heading", "text" => "H#{i}"}

      expanded = expand(long ++ [fragment_block(shared)])

      # Every host block, plus the one inlined block.
      assert length(expanded) == Fragments.max_nodes() + 51
      assert List.last(labels(expanded)) == "Shared"
    end

    test "a Columns-wrapped target cannot bypass the budget" do
      # `do_expand/5` maps a `Columns` to exactly ONE element however many
      # children it holds, so charging the returned list's length let a target
      # whose whole payload sat inside a column cost 1 node while emitting the
      # lot: 400 refs at a 1200-child target emitted 480,400 blocks in 54s.
      kids = for i <- 1..300, do: %{"_type" => "heading", "text" => "K#{i}"}
      cols = %{"_type" => "columns", "columns" => for(_ <- 1..4, do: %{"blocks" => kids})}
      target = page(%{blocks: [cols]})

      expanded = expand(List.duplicate(fragment_block(target), 400))

      # Each inlined container charges its 1200 children plus itself, so the
      # budget stops this in single digits rather than after 400 of them.
      assert length(expanded) < 20
    end
  end

  test "a historical expansion is no more permissive than a live one (#917)" do
    # `?as_of=` reaches `PointInTime.read/5` from an UNAUTHENTICATED route, and
    # the response is served `cache-control: public, max-age=300`. A historical
    # path that skipped the audience filter therefore let an anonymous caller
    # append `?as_of=` to any public URL and read — and have a CDN cache — the
    # body of a `:member` fragment embedded in it.
    # A REAL published page — `Ash.Seed.seed!` writes no version rows, and with
    # no history `snapshot_state/4` answers `:absent` whatever the audience
    # check does, which makes the historical assertion true for the wrong
    # reason.
    actor = admin()

    gated =
      CMS.create_page!(
        %{
          title: "Gated",
          slug: "fr-#{uniq()}",
          audience: :member,
          blocks: [%{"_type" => "heading", "text" => "Members only"}]
        },
        actor: actor
      )

    gated = CMS.publish_page!(gated, %{}, actor: actor)
    as_of = DateTime.utc_now()

    # Control: the history IS there, so a member reader gets it historically.
    assert labels(expand([fragment_block(gated)], as_of: as_of, audiences: [:member])) ==
             ["Members only"]

    # A public reader gets nothing, live AND historically.
    assert expand([fragment_block(gated)]) == []
    assert expand([fragment_block(gated)], as_of: as_of) == []
  end

  describe "withdrawing a fragment (#917)" do
    # The whole point of the feature's re-fire wave, and the one case it did not
    # cover. A referrer INLINES what it points at, so the target's body sits in
    # every referrer's artifacts too — and the wave was wired to the publish
    # path only. Unpublishing a fragment therefore left every page embedding it
    # serving the withdrawn body to anonymous callers, through feeds, static
    # export and the newsletter.
    #
    # Withdrawing is the operation an editor reaches for to *retract*.
    defp real_page(attrs, actor) do
      page = CMS.create_page!(Map.put_new(attrs, :slug, "fr-#{uniq()}"), actor: actor)
      CMS.publish_page!(page, %{}, actor: actor)
    end

    defp admin do
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "frag-#{uniq()}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })
    end

    test "unpublishing enqueues a re-fire of every referrer" do
      actor = admin()

      shared =
        real_page(
          %{title: "Shared", blocks: [%{"_type" => "heading", "text" => "Retract"}]},
          actor
        )

      host = real_page(%{title: "Host", blocks: [fragment_block(shared)]}, actor)

      # The edge only exists once the host has fired.
      drain_oban()

      CMS.unpublish_page!(shared, %{}, actor: actor)

      # The wave is enqueued, not run inline — assert on the job, then drain and
      # assert the host's artifact no longer carries the withdrawn body.
      assert Enum.any?(
               all_enqueued(worker: KilnCMS.Firing.RefireWorker),
               &(&1.args["id"] == host.id)
             )

      drain_oban()

      {:ok, artifacts} = Engine.fire(Ash.reload!(host, authorize?: false), mode: :preview)
      refute artifacts[:web]["html"] =~ "Retract"
    end

    test "archiving a fragment re-fires its referrers too" do
      actor = admin()

      shared =
        real_page(%{title: "Shared", blocks: [%{"_type" => "heading", "text" => "Gone"}]}, actor)

      host = real_page(%{title: "Host", blocks: [fragment_block(shared)]}, actor)
      drain_oban()

      CMS.archive_page!(shared, %{}, actor: actor)

      assert Enum.any?(
               all_enqueued(worker: KilnCMS.Firing.RefireWorker),
               &(&1.args["id"] == host.id)
             )
    end
  end
end
