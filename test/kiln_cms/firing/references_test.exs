defmodule KilnCMS.Firing.ReferencesTest do
  @moduledoc "Phase E — reference-aware invalidation: firing is a graph walk (D13)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.{CMS, Firing}
  alias KilnCMS.Firing.References

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ref-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "ref-#{System.unique_integer([:positive])}"

  defp ref_block(target_id),
    do: %{
      type: :custom,
      content: "see also",
      data: %{"ref" => %{"type" => "page", "id" => target_id}},
      order: 0
    }

  defp drain, do: KilnCMS.DataCase.drain_oban()

  describe "extract/1" do
    test "pulls reference edges out of legacy ref blocks via the bridge" do
      typed = KilnCMS.CMS.TypedBlocks.from_legacy([ref_block("abc123")])
      assert References.extract(typed) == [{:page, "abc123"}]
    end

    test "a document with no references yields no edges (tree walk suffices)" do
      typed = KilnCMS.CMS.TypedBlocks.from_legacy([%{type: :heading, content: "x"}])
      assert References.extract(typed) == []
    end
  end

  describe "edge rebuild on fire" do
    test "publishing a referrer records its outgoing edge" do
      actor = admin()
      target = CMS.create_page!(%{title: "B", slug: slug()}, actor: actor)
      _target = CMS.publish_page!(target, actor: actor)

      referrer =
        CMS.create_page!(%{title: "A", slug: slug(), blocks: [ref_block(target.id)]},
          actor: actor
        )

      referrer = CMS.publish_page!(referrer, actor: actor)
      drain()

      {:ok, edges} = Firing.edges_from(:page, referrer.id, authorize?: false)
      assert [%{to_type: :page, to_id: to_id}] = edges
      assert to_id == target.id
    end
  end

  describe "invalidation wave" do
    test "changing a referenced document re-fires its referrer" do
      actor = admin()
      target = CMS.create_page!(%{title: "B", slug: slug()}, actor: actor)
      target = CMS.publish_page!(target, actor: actor)

      referrer =
        CMS.create_page!(%{title: "A", slug: slug(), blocks: [ref_block(target.id)]},
          actor: actor
        )

      _referrer = CMS.publish_page!(referrer, actor: actor)
      drain()

      # Simulate target changing: invalidate its referrers.
      References.invalidate(:page, target.id, [References.key(:page, target.id)])
      assert %{success: 1, failure: 0} = drain()
    end

    test "is cycle-safe: A↔B re-fires each at most once" do
      actor = admin()

      b = CMS.create_page!(%{title: "B", slug: slug()}, actor: actor)
      a = CMS.create_page!(%{title: "A", slug: slug(), blocks: [ref_block(b.id)]}, actor: actor)

      # Make B reference A as well (the cycle), then publish both so edges exist.
      b = CMS.update_page!(b, %{blocks: [ref_block(a.id)]}, actor: actor)
      b = CMS.publish_page!(b, actor: actor)
      _a = CMS.publish_page!(a, actor: actor)
      drain()

      # Invalidating B enqueues A; A's own propagation hits B but B is in the
      # visited set, so the wave fires exactly one node (A) and stops.
      References.invalidate(:page, b.id, [References.key(:page, b.id)])
      assert %{success: 1, failure: 0} = drain()
    end
  end
end
