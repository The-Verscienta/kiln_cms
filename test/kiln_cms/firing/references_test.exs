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
      typed = KilnCMS.CMS.TypedBlocks.to_typed([ref_block("abc123")])
      assert References.extract(typed) == [{:page, "abc123"}]
    end

    test "a document with no references yields no edges (tree walk suffices)" do
      typed = KilnCMS.CMS.TypedBlocks.to_typed([%{type: :heading, content: "x"}])
      assert References.extract(typed) == []
    end
  end

  describe "edge rebuild on fire" do
    test "publishing a referrer records its outgoing edge" do
      actor = admin()
      target = CMS.create_page!(%{title: "B", slug: slug()}, actor: actor)
      _target = CMS.publish_page!(target, actor: actor)

      referrer =
        CMS.create_page!(
          %{
            title: "A",
            slug: slug(),
            blocks: KilnCMS.TypedFixtures.typed_blocks([ref_block(target.id)])
          },
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
        CMS.create_page!(
          %{
            title: "A",
            slug: slug(),
            blocks: KilnCMS.TypedFixtures.typed_blocks([ref_block(target.id)])
          },
          actor: actor
        )

      _referrer = CMS.publish_page!(referrer, actor: actor)
      drain()

      # Simulate target changing: invalidate its referrers.
      org = KilnCMS.Accounts.default_org_id()
      References.invalidate(org, :page, target.id, [References.key(:page, target.id)])
      assert %{success: 1, failure: 0} = drain()
    end

    test "is cycle-safe: A↔B re-fires each at most once" do
      actor = admin()

      b = CMS.create_page!(%{title: "B", slug: slug()}, actor: actor)

      a =
        CMS.create_page!(
          %{
            title: "A",
            slug: slug(),
            blocks: KilnCMS.TypedFixtures.typed_blocks([ref_block(b.id)])
          },
          actor: actor
        )

      # Make B reference A as well (the cycle), then publish both so edges exist.
      b =
        CMS.update_page!(b, %{blocks: KilnCMS.TypedFixtures.typed_blocks([ref_block(a.id)])},
          actor: actor
        )

      b = CMS.publish_page!(b, actor: actor)
      _a = CMS.publish_page!(a, actor: actor)
      drain()

      # Invalidating B enqueues A; A's own propagation hits B but B is in the
      # visited set, so the wave fires exactly one node (A) and stops.
      org = KilnCMS.Accounts.default_org_id()
      References.invalidate(org, :page, b.id, [References.key(:page, b.id)])
      assert %{success: 1, failure: 0} = drain()
    end
  end

  # `:reference` custom fields are references the document carries itself, not
  # in a block — they used to be mirrored as `ContentLink` backlinks (#1594) but
  # never entered this graph, so renaming a target left its referrers' artifacts
  # firing the old title.
  describe "reference custom fields" do
    setup do
      actor = admin()

      definition =
        CMS.create_type_definition!(
          %{name: "rf#{System.unique_integer([:positive])}", label: "Referrer"},
          actor: actor
        )

      for {name, type, target} <- [{"related", :reference, "page"}, {"hero", :media, nil}] do
        CMS.create_field_definition!(
          %{
            type_definition_id: definition.id,
            name: name,
            label: name,
            field_type: type,
            target_type: target
          },
          actor: actor
        )
      end

      %{actor: actor, definition: definition, org: KilnCMS.Accounts.default_org_id()}
    end

    defp media! do
      Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
        filename: "hero-#{System.unique_integer([:positive])}.png",
        url: "/uploads/hero.png",
        alt: "A hero image"
      })
    end

    defp published_referrer!(definition, fields, actor) do
      definition.name
      |> CMS.ContentTypes.create!(%{title: "Referrer", slug: slug(), custom_fields: fields},
        actor: actor
      )
      |> CMS.publish_entry!(%{}, actor: actor)
    end

    defp json_artifact(org, type, id) do
      {:ok, artifact} = Firing.get_artifact(type, id, :json, authorize?: false, tenant: org)
      artifact.body
    end

    test "a reference is a content edge and a media field stays a media edge", %{
      actor: actor,
      definition: definition
    } do
      target =
        CMS.publish_page!(CMS.create_page!(%{title: "B", slug: slug()}, actor: actor),
          actor: actor
        )

      media = media!()

      referrer =
        published_referrer!(definition, %{"related" => target.id, "hero" => media.id}, actor)

      drain()

      {:ok, edges} = Firing.edges_from(:entry, referrer.id, authorize?: false)
      targets = edges |> Enum.map(&{&1.to_type, &1.to_id}) |> Enum.sort()

      assert targets == Enum.sort([{:page, target.id}, {:media, media.id}])
    end

    test "every item of a list of references is an edge, and a rename re-fires the list", %{
      actor: actor,
      definition: definition,
      org: org
    } do
      CMS.create_field_definition!(
        %{
          type_definition_id: definition.id,
          name: "see_also",
          label: "See also",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        actor: actor
      )

      [a, b] =
        for title <- ["First", "Second"] do
          CMS.publish_page!(CMS.create_page!(%{title: title, slug: slug()}, actor: actor),
            actor: actor
          )
        end

      referrer = published_referrer!(definition, %{"see_also" => [b.id, a.id]}, actor)
      drain()

      {:ok, edges} = Firing.edges_from(:entry, referrer.id, authorize?: false)

      assert edges |> Enum.map(&{&1.to_type, &1.to_id}) |> Enum.sort() ==
               Enum.sort([{:page, a.id}, {:page, b.id}])

      CMS.update_page!(a, %{title: "First, renamed"}, actor: actor)
      assert %{failure: 0} = drain()

      fired = json_artifact(org, :entry, referrer.id)["custom_fields"]["see_also"]

      # The list keeps its order and shape; only the renamed item's label moves.
      assert Enum.map(fired, &{&1["id"], &1["title"]}) == [
               {b.id, "Second"},
               {a.id, "First, renamed"}
             ]
    end

    test "renaming the target re-fires the referrer with the new title", %{
      actor: actor,
      definition: definition,
      org: org
    } do
      target =
        CMS.publish_page!(CMS.create_page!(%{title: "Old title", slug: slug()}, actor: actor),
          actor: actor
        )

      referrer = published_referrer!(definition, %{"related" => target.id}, actor)
      drain()

      assert %{"title" => "Old title"} =
               json_artifact(org, :entry, referrer.id)["custom_fields"]["related"]

      renamed = CMS.update_page!(target, %{title: "New title"}, actor: actor)
      assert %{failure: 0} = drain()

      fired = json_artifact(org, :entry, referrer.id)["custom_fields"]["related"]

      assert fired == %{
               "id" => target.id,
               "type" => "page",
               "slug" => renamed.slug,
               "title" => "New title"
             }

      # The stored snapshot keeps its 1.0 shape and is not rewritten by firing.
      assert %{"title" => "Old title"} =
               CMS.get_entry!(referrer.id, actor: actor).custom_fields["related"]
    end

    # The artifact is served to anyone, and the stored snapshot names the
    # draft's id, slug and title: neither the stored label nor the draft's
    # current one leaves (`KilnCMS.CMS.ReferenceSnapshots`). The stored value
    # is kept.
    test "an unpublished target is left out of the artifact", %{
      actor: actor,
      definition: definition,
      org: org
    } do
      target = CMS.create_page!(%{title: "Draft title", slug: slug()}, actor: actor)
      referrer = published_referrer!(definition, %{"related" => target.id}, actor)
      CMS.update_page!(target, %{title: "Secret new title"}, actor: actor)
      drain()

      custom = json_artifact(org, :entry, referrer.id)["custom_fields"]
      assert Map.has_key?(custom, "related")
      assert custom["related"] == nil

      assert %{"title" => "Draft title"} =
               CMS.get_entry!(referrer.id, actor: actor).custom_fields["related"]
    end

    test "a cycle through a custom field and a block reference terminates", %{
      actor: actor,
      definition: definition,
      org: org
    } do
      page = CMS.create_page!(%{title: "Old title", slug: slug()}, actor: actor)
      entry = published_referrer!(definition, %{"related" => page.id}, actor)

      block = %{
        type: :custom,
        content: "see also",
        data: %{"ref" => %{"type" => definition.name, "id" => entry.id}},
        order: 0
      }

      page =
        page
        |> CMS.update_page!(%{blocks: KilnCMS.TypedFixtures.typed_blocks([block])}, actor: actor)
        |> CMS.publish_page!(actor: actor)

      drain()

      {:ok, [edge]} = Firing.edges_from(:page, page.id, authorize?: false)
      assert {edge.to_type, edge.to_id} == {:entry, entry.id}

      # page → entry → page: the wave fires the entry once and stops at the
      # page, which is already in its visited set.
      CMS.update_page!(page, %{title: "New title"}, actor: actor)
      assert %{failure: 0} = drain()

      assert %{"title" => "New title"} =
               json_artifact(org, :entry, entry.id)["custom_fields"]["related"]
    end
  end

  describe "document_refs/1 on custom fields" do
    test "tells a reference snapshot from a media snapshot and from plain JSON" do
      media = Ecto.UUID.generate()
      page = Ecto.UUID.generate()
      posts = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      document = %{
        blocks: [],
        featured_image_id: nil,
        custom_fields: %{
          "hero" => %{"id" => media, "url" => "/uploads/a.png", "alt" => "A"},
          "related" => %{"id" => page, "type" => "page", "slug" => "p", "title" => "P"},
          "more" =>
            Enum.map(posts, &%{"id" => &1, "type" => "post", "slug" => "s", "title" => "T"}),
          "raw" => %{"id" => Ecto.UUID.generate(), "type" => "page"}
        }
      }

      refs = References.document_refs(document)

      assert Enum.sort(refs) ==
               Enum.sort([{:media, media}, {:page, page} | Enum.map(posts, &{:post, &1})])
    end
  end
end
