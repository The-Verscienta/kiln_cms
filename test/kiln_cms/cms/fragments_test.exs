defmodule KilnCMS.CMS.FragmentsTest do
  @moduledoc """
  Reusable content fragments (#479): inlining at fire time, the fail-closed
  visibility rules, cycle and depth bounds, and the reference edge that makes
  editing a fragment re-fire everything embedding it.
  """
  use KilnCMS.DataCase, async: true

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
end
