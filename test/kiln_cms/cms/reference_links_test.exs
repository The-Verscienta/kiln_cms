defmodule KilnCMS.CMS.ReferenceLinksTest do
  @moduledoc """
  `:reference` custom fields keep their jsonb snapshot and gain a
  `ContentLink` edge (#1594): written with the live value, reconciled on every
  change of it, never for a working copy's held value, readable only when both
  ends are, and backfilled for values stored before 1.1.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentLink
  alias KilnCMS.CMS.ContentLinks
  alias KilnCMS.CMS.ContentLinks.Backfill

  require Ash.Query

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "refl-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "refl-#{System.unique_integer([:positive])}"

  defp page!(admin, title, publish? \\ true) do
    page = CMS.create_page!(%{title: title, slug: slug()}, actor: admin)
    if publish?, do: CMS.publish_page!(page, %{}, actor: admin), else: page
  end

  defp reference_field!(admin, name) do
    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: name,
        label: String.capitalize(name),
        field_type: :reference,
        target_type: "page"
      },
      actor: admin
    )
  end

  defp post!(admin, fields, attrs \\ %{}) do
    CMS.create_post!(Map.merge(%{title: "Referrer", slug: slug(), custom_fields: fields}, attrs),
      actor: admin
    )
  end

  # Every edge in the table for `source`, bypassing policy: what was written.
  defp edges(source) do
    ContentLink
    |> Ash.Query.filter(source_id == ^source.id and kind == :reference)
    |> Ash.Query.sort(field: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp edge_keys(source), do: Enum.map(edges(source), &{&1.field, &1.target_id})

  setup do
    admin = user(:admin)
    reference_field!(admin, "hero")
    reference_field!(admin, "sidekick")
    %{admin: admin}
  end

  describe "dual-write" do
    test "a create writes one edge per reference value, snapshot unchanged", %{admin: admin} do
      target = page!(admin, "Target")
      post = post!(admin, %{"hero" => target.id})

      # The 1.0 snapshot keeps its shape and meaning.
      assert post.custom_fields["hero"] == %{
               "id" => target.id,
               "type" => "page",
               "slug" => target.slug,
               "title" => "Target"
             }

      assert [edge] = edges(post)
      assert edge.target_id == target.id
      assert edge.field == "hero"
      assert edge.kind == :reference
      assert edge.source_type == "post"
      assert edge.target_type == "page"
      assert edge.position == 0
      assert edge.org_id == post.org_id
    end

    test "re-pointing, adding and clearing a field reconcile the edges", %{admin: admin} do
      first = page!(admin, "First")
      second = page!(admin, "Second")
      post = post!(admin, %{"hero" => first.id})

      post = CMS.update_post!(post, %{custom_fields: %{"hero" => second.id}}, actor: admin)
      assert edge_keys(post) == [{"hero", second.id}]

      post = CMS.update_post!(post, %{custom_fields: %{"sidekick" => first.id}}, actor: admin)
      assert edge_keys(post) == [{"hero", second.id}, {"sidekick", first.id}]

      post = CMS.update_post!(post, %{custom_fields: %{"hero" => ""}}, actor: admin)
      assert edge_keys(post) == [{"sidekick", first.id}]
    end

    test "two fields naming the same target are two edges", %{admin: admin} do
      target = page!(admin, "Shared")
      post = post!(admin, %{"hero" => target.id, "sidekick" => target.id})

      assert edge_keys(post) == [{"hero", target.id}, {"sidekick", target.id}]
    end

    test "a write that leaves custom_fields alone touches no edge", %{admin: admin} do
      target = page!(admin, "Kept")
      post = post!(admin, %{"hero" => target.id})
      [before] = edges(post)

      CMS.update_post!(post, %{title: "Retitled"}, actor: admin)

      assert [^before] = edges(post)
    end

    test "trash keeps the edges for a restore; purge removes them", %{admin: admin} do
      target = page!(admin, "Target")
      post = post!(admin, %{"hero" => target.id})

      :ok = CMS.destroy_post!(post, actor: admin)
      assert [_edge] = edges(post)

      [trashed] = CMS.list_trashed_posts!(actor: admin) |> Enum.filter(&(&1.id == post.id))
      CMS.purge_post!(trashed, actor: admin)
      assert edges(post) == []
    end
  end

  describe "the working copy" do
    test "a held reference is no edge until its changes are published", %{admin: admin} do
      first = page!(admin, "Live target")
      second = page!(admin, "Draft target")
      post = post!(admin, %{"hero" => first.id})
      post = CMS.publish_post!(post, %{}, actor: admin)

      {:ok, saved} =
        CMS.save_post_working_copy(
          post,
          %{fields: %{"custom_fields" => %{"hero" => second.id}}},
          actor: admin,
          tenant: post.org_id
        )

      assert KilnCMS.CMS.WorkingCopy.pending?(saved)
      assert edge_keys(post) == [{"hero", first.id}]

      {:ok, _live} = CMS.publish_post_changes(saved, %{}, actor: admin)
      assert edge_keys(post) == [{"hero", second.id}]
    end
  end

  describe "related content" do
    test "reference edges are not related content, and saving related keeps them",
         %{admin: admin} do
      referenced = page!(admin, "Referenced")
      related = page!(admin, "Related")

      post = post!(admin, %{"hero" => referenced.id})

      # `related_posts` is post → post; a reference to a page is not in it,
      # and replacing the set must not delete the reference edge.
      other = post!(admin, %{})
      post = CMS.update_post!(post, %{related_post_ids: [other.id]}, actor: admin)
      post = Ash.load!(post, [:related_posts, :content_links], actor: admin)

      assert Enum.map(post.related_posts, & &1.id) == [other.id]
      assert edge_keys(post) == [{"hero", referenced.id}]
      assert length(post.content_links) == 2

      # A reference to a post that is *also* curated as related: removing it
      # from related deletes the curated link, never the reference edge.
      reference_post_field!(admin)
      post = CMS.update_post!(post, %{custom_fields: %{"buddy" => other.id}}, actor: admin)
      post = CMS.update_post!(post, %{related_post_ids: []}, actor: admin)
      post = Ash.load!(post, [:related_posts], actor: admin)

      assert post.related_posts == []
      assert {"buddy", other.id} in edge_keys(post)
      refute related.id in Enum.map(edges(post), & &1.target_id)
    end
  end

  defp reference_post_field!(admin) do
    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: "buddy",
        label: "Buddy",
        field_type: :reference,
        target_type: "post"
      },
      actor: admin
    )
  end

  describe "who may read an edge" do
    test "a reader sees an edge only when both ends are readable", %{admin: admin} do
      editor = user(:editor)
      target = page!(admin, "Public target")

      published = post!(admin, %{"hero" => target.id})
      published = CMS.publish_post!(published, %{}, actor: admin)
      draft = post!(admin, %{"hero" => target.id}, %{title: "Secret draft"})

      sources = fn actor ->
        target.id
        |> CMS.list_backlinks!(actor: actor, tenant: target.org_id)
        |> Enum.map(& &1.source_id)
        |> Enum.sort()
      end

      # Anonymous: the draft's edge — and so its id — is not there.
      assert sources.(nil) == [published.id]

      # Through the relationship too, which is what `?include=` serves.
      page = CMS.get_page!(target.id, load: [:incoming_links])
      assert Enum.map(page.incoming_links, & &1.source_id) == [published.id]

      # Editors see every edge of their site.
      assert sources.(editor) == Enum.sort([published.id, draft.id])
    end

    test "an edge to an unpublished target is hidden from a published source's readers",
         %{admin: admin} do
      hidden = page!(admin, "Not yet", false)
      post = post!(admin, %{"hero" => hidden.id})
      CMS.publish_post!(post, %{}, actor: admin)

      loaded = CMS.get_post!(post.id, load: [:content_links])
      assert loaded.content_links == []

      assert [_edge] = Ash.load!(post, :content_links, actor: admin).content_links
    end

    test "backlinks/2 loads the sources the actor may open", %{admin: admin} do
      target = page!(admin, "Linked")
      post = post!(admin, %{"hero" => target.id}, %{title: "Referrer draft"})

      assert [%{link: link, source: source}] = ContentLinks.backlinks(target, actor: admin)
      assert link.field == "hero"
      assert source.id == post.id
      assert source.title == "Referrer draft"

      assert ContentLinks.backlinks(target, actor: nil) == []
    end

    test "broken/2 lists edges whose target is gone", %{admin: admin} do
      target = page!(admin, "Doomed")
      post = post!(admin, %{"hero" => target.id})

      assert ContentLinks.broken(post, actor: admin) == []

      :ok = CMS.destroy_page!(target, actor: admin)
      assert [%{target_id: id}] = ContentLinks.broken(post, actor: admin)
      assert id == target.id
    end
  end

  describe "field definitions" do
    test "renaming a field moves its edges; destroying it deletes them", %{admin: admin} do
      target = page!(admin, "Target")
      post = post!(admin, %{"hero" => target.id, "sidekick" => target.id})

      [hero] =
        CMS.field_definitions_for!(:post, authorize?: false)
        |> Enum.filter(&(&1.name == "hero"))

      hero = CMS.update_field_definition!(hero, %{name: "lead"}, actor: admin)
      assert edge_keys(post) == [{"lead", target.id}, {"sidekick", target.id}]

      :ok = CMS.destroy_field_definition!(hero, actor: admin)
      assert edge_keys(post) == [{"sidekick", target.id}]
    end
  end

  describe "backfill" do
    test "writes edges for values stored before 1.1, idempotently", %{admin: admin} do
      target = page!(admin, "Old target")

      # A 1.0 row: the snapshot is stored, no edge was ever written.
      old =
        Ash.Seed.seed!(KilnCMS.CMS.Post, %{
          title: "Old",
          slug: slug(),
          custom_fields: %{
            "hero" => %{"id" => target.id, "type" => "page", "slug" => "x", "title" => "X"},
            "sidekick" => %{"id" => "not-a-uuid"}
          }
        })

      assert edges(old) == []

      assert %{inserted: inserted} = Backfill.run()
      assert inserted >= 1
      assert [edge] = edges(old)

      assert {edge.field, edge.target_id, edge.source_type, edge.target_type} ==
               {"hero", target.id, "post", "page"}

      assert %{inserted: 0, deleted: 0} = Backfill.run()
    end

    test "prunes an edge no stored value implies", %{admin: admin} do
      target = page!(admin, "Target")
      post = post!(admin, %{"hero" => target.id})

      # The value moved without the write path (a raw SQL import, say).
      Ecto.Adapters.SQL.query!(
        KilnCMS.Repo,
        "UPDATE posts SET custom_fields = '{}'::jsonb WHERE id = $1",
        [Ecto.UUID.dump!(post.id)]
      )

      assert %{deleted: 1} = Backfill.run()
      assert edges(post) == []
    end
  end
end
