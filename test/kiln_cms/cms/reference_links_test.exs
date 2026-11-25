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

  defp list_field!(admin) do
    name = "related_#{System.unique_integer([:positive])}"

    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: name,
        label: "Related",
        field_type: :reference,
        target_type: "page",
        multiple: true
      },
      actor: admin
    )

    name
  end

  defp snapshot(page),
    do: %{"id" => page.id, "type" => "page", "slug" => page.slug, "title" => page.title}

  # A row stored without the write path: no snapshot cast, no edge.
  defp seed_post!(fields),
    do: Ash.Seed.seed!(KilnCMS.CMS.Post, %{title: "Old", slug: slug(), custom_fields: fields})

  # Overwrites a row's custom fields without the write path (a raw import).
  defp set_fields!(table, record, fields) do
    Ecto.Adapters.SQL.query!(
      KilnCMS.Repo,
      "UPDATE #{table} SET custom_fields = $1 WHERE id = $2",
      [fields, Ecto.UUID.dump!(record.id)]
    )
  end

  defp positioned(source),
    do: source |> edges() |> Enum.map(&{&1.field, &1.target_id, &1.position}) |> Enum.sort()

  # The edges in the table are exactly the ones the write path would keep for
  # the stored value: `reconcile/1` keys `desired/2` by (field, target), last
  # occurrence winning, and the uuid column reads back in lower case.
  defp assert_desired(record) do
    record = reload!(record)

    want =
      record.custom_fields
      |> ContentLinks.desired(ContentLinks.reference_definitions(record))
      |> Enum.map(&%{&1 | target_id: String.downcase(&1.target_id)})
      |> Map.new(&{{&1.field, &1.target_id}, &1})
      |> Map.values()
      |> Enum.map(&{&1.field, &1.target_id, &1.position, &1.metadata, &1.target_type})
      |> Enum.sort()

    got =
      record
      |> edges()
      |> Enum.map(&{&1.field, &1.target_id, &1.position, &1.metadata, &1.target_type})
      |> Enum.sort()

    assert got == want
  end

  defp reload!(%KilnCMS.CMS.Post{id: id}), do: CMS.get_post!(id, authorize?: false)
  defp reload!(%KilnCMS.CMS.Entry{id: id}), do: CMS.get_entry!(id, authorize?: false)

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

    # #2742: before the fix, a list value's edges were deleted and never
    # written, and a nested path's edge was deleted too.
    test "keeps the edges of a list value the write path wrote", %{admin: admin} do
      list = list_field!(admin)
      [a, b, c] = for t <- ~w(A B C), do: page!(admin, t)
      post = post!(admin, %{list => [a.id, b.id, c.id]})

      assert %{inserted: 0, deleted: 0} = Backfill.run()
      assert positioned(post) == Enum.sort([{list, a.id, 0}, {list, b.id, 1}, {list, c.id, 2}])
      assert_desired(post)
    end

    test "writes one edge per resolved element of a stored list, at its index", %{admin: admin} do
      list = list_field!(admin)
      a = page!(admin, "A")
      b = page!(admin, "B")

      old =
        seed_post!(%{
          list => [
            Map.put(snapshot(a), "link", %{"role" => "x"}),
            "not-a-uuid",
            %{"id" => "nope"},
            snapshot(b)
          ]
        })

      assert %{inserted: 2, deleted: 0} = Backfill.run()
      assert positioned(old) == Enum.sort([{list, a.id, 0}, {list, b.id, 3}])
      assert Enum.find(edges(old), &(&1.target_id == a.id)).metadata == %{"role" => "x"}
      assert_desired(old)

      assert Backfill.run() == %{inserted: 0, updated: 0, deleted: 0}
    end

    test "rewrites a list value's deleted edges in order", %{admin: admin} do
      list = list_field!(admin)
      [a, b, c] = for t <- ~w(A B C), do: page!(admin, t)
      post = post!(admin, %{list => [a.id, b.id, c.id]})

      Ecto.Adapters.SQL.query!(KilnCMS.Repo, "DELETE FROM content_links WHERE source_id = $1", [
        Ecto.UUID.dump!(post.id)
      ])

      assert %{inserted: 3, deleted: 0} = Backfill.run()
      assert positioned(post) == Enum.sort([{list, a.id, 0}, {list, b.id, 1}, {list, c.id, 2}])
    end

    test "prunes a dropped element and realigns the rest", %{admin: admin} do
      list = list_field!(admin)
      [a, b, c] = for t <- ~w(A B C), do: page!(admin, t)
      post = post!(admin, %{list => [a.id, b.id, c.id]})

      set_fields!("posts", post, %{list => [snapshot(a), snapshot(c)]})

      assert %{inserted: 0, deleted: 1} = result = Backfill.run()
      assert result.updated == 1
      assert positioned(post) == Enum.sort([{list, a.id, 0}, {list, c.id, 1}])
      assert_desired(post)

      assert Backfill.run() == %{inserted: 0, updated: 0, deleted: 0}
    end

    test "writes a single and a list reference of one record", %{admin: admin} do
      list = list_field!(admin)
      [a, b, c] = for t <- ~w(A B C), do: page!(admin, t)
      old = seed_post!(%{"hero" => snapshot(a), list => [snapshot(b), snapshot(c)]})

      assert %{inserted: 3, deleted: 0} = Backfill.run()

      assert positioned(old) ==
               Enum.sort([{"hero", a.id, 0}, {list, b.id, 0}, {list, c.id, 1}])

      assert_desired(old)
    end

    test "values that resolve to no target imply no edge", %{admin: admin} do
      list = list_field!(admin)
      empty = list_field!(admin)
      a = page!(admin, "A")

      old =
        seed_post!(%{
          "hero" => a.id,
          "sidekick" => nil,
          list => [a.id],
          empty => []
        })

      assert %{inserted: 0} = Backfill.run()
      assert edges(old) == []
      assert_desired(old)

      # The write path snapshots bare ids; a raw import may store JSON null.
      written = post!(admin, %{list => [a.id, page!(admin, "B").id]})
      assert length(edges(written)) == 2
      set_fields!("posts", written, %{list => [], "hero" => nil})

      assert %{deleted: 2} = Backfill.run()
      assert edges(written) == []
    end

    test "a target named twice in a list is one edge, at its last place", %{admin: admin} do
      list = list_field!(admin)
      a = page!(admin, "A")
      b = page!(admin, "B")
      old = seed_post!(%{list => [snapshot(a), snapshot(b), snapshot(a)]})

      assert %{inserted: 2, deleted: 0} = Backfill.run()
      assert positioned(old) == Enum.sort([{list, a.id, 2}, {list, b.id, 1}])
      assert_desired(old)
      assert Backfill.run() == %{inserted: 0, updated: 0, deleted: 0}
    end

    test "an upper-case id is the edge the uuid column holds", %{admin: admin} do
      a = page!(admin, "A")
      old = seed_post!(%{"hero" => %{snapshot(a) | "id" => String.upcase(a.id)}})

      assert %{inserted: 1, deleted: 0} = Backfill.run()
      assert positioned(old) == [{"hero", a.id, 0}]
      assert_desired(old)
      assert Backfill.run() == %{inserted: 0, updated: 0, deleted: 0}
    end

    test "keeps a nested reference edge while its source exists", %{admin: admin} do
      visits =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: "visits",
            label: "Visits",
            field_type: :group,
            multiple: true
          },
          actor: admin
        )

      %{name: "doctor", label: "Doctor", group_of_id: visits.id, field_type: :string}
      |> CMS.create_field_definition!(actor: admin)
      # A plain group's rows are not lifted: retype directly.
      |> Ash.Seed.update!(%{field_type: :reference, target_type: "page"})

      a = page!(admin, "A")
      post = post!(admin, %{"visits" => [%{"doctor" => a.id}]})
      assert edge_keys(post) == [{"visits.doctor", a.id}]

      assert %{deleted: 0} = Backfill.run()
      assert edge_keys(post) == [{"visits.doctor", a.id}]

      Ecto.Adapters.SQL.query!(KilnCMS.Repo, "DELETE FROM posts WHERE id = $1", [
        Ecto.UUID.dump!(post.id)
      ])

      assert %{deleted: 1} = Backfill.run()
      assert edges(post) == []
    end

    test "writes, realigns and prunes a dynamic type's list edges", %{admin: admin} do
      type =
        CMS.create_type_definition!(
          %{name: "gadget#{System.unique_integer([:positive])}", label: "Gadget"},
          actor: admin
        )

      CMS.create_field_definition!(
        %{
          type_definition_id: type.id,
          name: "parts",
          label: "Parts",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        actor: admin
      )

      [a, b, c] = for t <- ~w(A B C), do: page!(admin, t)

      entry =
        Ash.Seed.seed!(KilnCMS.CMS.Entry, %{
          title: "Old entry",
          slug: slug(),
          type_definition_id: type.id,
          custom_fields: %{
            "parts" => [
              Map.put(snapshot(a), "link", %{"qty" => 2}),
              "junk",
              %{"id" => "nope"},
              snapshot(b),
              snapshot(c)
            ]
          }
        })

      assert %{inserted: 3, deleted: 0} = Backfill.run()
      assert Enum.all?(edges(entry), &(&1.source_type == type.name))

      assert positioned(entry) ==
               Enum.sort([{"parts", a.id, 0}, {"parts", b.id, 3}, {"parts", c.id, 4}])

      assert_desired(entry)
      assert Backfill.run() == %{inserted: 0, updated: 0, deleted: 0}

      set_fields!("entries", entry, %{"parts" => [snapshot(c), snapshot(a)]})

      assert Backfill.run() == %{inserted: 0, updated: 2, deleted: 1}
      assert positioned(entry) == Enum.sort([{"parts", c.id, 0}, {"parts", a.id, 1}])
      assert Enum.find(edges(entry), &(&1.target_id == a.id)).metadata == %{}
      assert_desired(entry)
      assert Backfill.run() == %{inserted: 0, updated: 0, deleted: 0}
    end

    test "realigns a list element whose link values changed in place", %{admin: admin} do
      list = list_field!(admin)
      a = page!(admin, "A")
      b = page!(admin, "B")
      linked = fn role -> Map.put(snapshot(a), "link", %{"role" => role}) end
      old = seed_post!(%{list => [linked.("x"), snapshot(b)]})

      assert %{inserted: 2, updated: 0, deleted: 0} = Backfill.run()

      set_fields!("posts", old, %{list => [linked.("y"), snapshot(b)]})

      assert Backfill.run() == %{inserted: 0, updated: 1, deleted: 0}
      assert Enum.find(edges(old), &(&1.target_id == a.id)).metadata == %{"role" => "y"}
      assert positioned(old) == Enum.sort([{list, a.id, 0}, {list, b.id, 1}])
      assert_desired(old)
    end

    test "realigns a single reference's drifted position and link values", %{admin: admin} do
      a = page!(admin, "A")
      post = post!(admin, %{"hero" => a.id})
      assert_desired(post)

      drift! = fn set ->
        Ecto.Adapters.SQL.query!(
          KilnCMS.Repo,
          "UPDATE content_links SET #{set} WHERE source_id = $1",
          [Ecto.UUID.dump!(post.id)]
        )
      end

      drift!.("position = 5")
      assert Backfill.run() == %{inserted: 0, updated: 1, deleted: 0}
      assert positioned(post) == [{"hero", a.id, 0}]

      drift!.(~S|metadata = '{"stale": true}'::jsonb|)
      assert Backfill.run() == %{inserted: 0, updated: 1, deleted: 0}
      assert [%{metadata: %{}}] = edges(post)
      assert_desired(post)
    end

    # The 1.1 data migration (20261003000000) runs this module against the
    # schema as of that migration, so a column added later would crash an
    # upgrade from 1.0. Every column the statements name must be one that
    # existed then (the moduledoc's list); an alias not listed here fails too.
    test "names only columns that existed at the 1.1 data migration" do
      content = ~w(id org_id custom_fields type_definition_id)

      link =
        ~w(id org_id source_id target_id kind position metadata field source_type target_type)

      allowed = %{
        # a content table
        "c" => content,
        "fd" => ~w(org_id content_type type_definition_id name field_type target_type),
        "td" => ~w(id name),
        "cl" => link,
        # the desired-rows subquery's own output
        "d" => ~w(org_id source_id field target_id position metadata source_type target_type),
        # jsonb_array_elements(...) WITH ORDINALITY AS e(v, ord)
        "e" => ~w(v ord)
      }

      statements = Backfill.statements()
      assert statements != []

      for sql <- statements do
        qualified =
          for [_, table, column] <- Regex.scan(~r/\b([a-z_]+)\.([a-z_]+)\b/, sql),
              do: {table, column}

        bare =
          (Regex.scan(~r/INSERT INTO content_links\s*\(([^)]*)\)/, sql) ++
             Regex.scan(~r/\bSET\s+(.*?)\s+FROM\b/s, sql))
          |> Enum.flat_map(fn [_, list] ->
            list |> String.split(",") |> Enum.map(&(&1 |> String.split("=") |> hd()))
          end)
          |> Enum.map(&{"cl", String.trim(&1)})

        assert qualified != []

        for {table, column} <- qualified ++ bare do
          assert column in Map.get(allowed, table, []),
                 "backfill SQL names `#{table}.#{column}`:\n#{sql}"
        end
      end
    end
  end
end
