defmodule KilnCMS.Portability.ExportTest do
  @moduledoc """
  Dumping content to a portable envelope (#487), and loading it back.

  The round-trip test is the one that matters: an export the importer cannot
  read is a report, not a backup.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Portability.Export
  alias KilnCMS.Portability.Import

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "export-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  setup do
    actor = user(:admin)

    {:ok, tag} = CMS.create_tag(%{name: "Guides", slug: "guides"}, actor: actor)
    {:ok, category} = CMS.create_category(%{name: "News", slug: "news"}, actor: actor)

    {:ok, post} =
      CMS.create_post(
        %{
          title: "Exportable",
          slug: "exportable",
          excerpt: "A summary.",
          seo_title: "SEO title",
          category_id: category.id,
          tag_ids: [tag.id],
          block_tree: [
            %{
              "_type" => "rich_text",
              "body" => [
                %{
                  "_type" => "block",
                  "style" => "normal",
                  "children" => [%{"_type" => "span", "text" => "Body text", "marks" => []}],
                  "markDefs" => []
                }
              ]
            },
            %{"_type" => "heading", "text" => "A heading", "level" => 2}
          ]
        },
        actor: actor
      )

    {:ok, draft} = CMS.create_page(%{title: "A draft", slug: "a-draft"}, actor: actor)

    %{actor: actor, post: post, draft: draft}
  end

  defp record(envelope, slug), do: Enum.find(envelope["records"], &(&1["slug"] == slug))

  describe "envelope" do
    test "carries a version and the types exported", %{actor: actor} do
      {:ok, envelope} = Export.run(:all, actor: actor)

      assert envelope["kiln_export"]["version"] == 1
      assert "post" in envelope["kiln_export"]["types"]
      assert envelope["kiln_export"]["exported_at"]
    end

    test "carries the authored fields", %{actor: actor} do
      {:ok, envelope} = Export.run([:post], actor: actor)
      post = record(envelope, "exportable")

      assert post["title"] == "Exportable"
      assert post["excerpt"] == "A summary."
      assert post["seo_title"] == "SEO title"
      assert post["locale"] == "en"
      assert post["type"] == "post"
    end

    # Slug AND display name. A uuid is meaningless in the target database, but
    # the slug alone made the importer rebuild every term as %{name: slug}, so a
    # fresh org's nav read "how-to" instead of "How To".
    test "references travel by slug and name, not by uuid", %{actor: actor} do
      {:ok, envelope} = Export.run([:post], actor: actor)
      post = record(envelope, "exportable")

      assert post["category"] == %{"slug" => "news", "name" => "News"}
      assert post["tags"] == [%{"slug" => "guides", "name" => "Guides"}]
    end

    test "blocks are dumped in the shape a create action accepts", %{actor: actor} do
      {:ok, envelope} = Export.run([:post], actor: actor)
      blocks = record(envelope, "exportable")["blocks"]

      assert length(blocks) == 2
      assert Enum.all?(blocks, &Map.has_key?(&1, "type"))
      assert Enum.any?(blocks, &(&1["type"] == "rich_text"))
    end

    # `dump_to_embedded` emits atom keys and an atom union tag. If those reached
    # the envelope, the same data would import from a FILE but not in memory —
    # a difference nothing would notice until someone piped the two together.
    test "the in-memory envelope is identical to its JSON round trip", %{actor: actor} do
      {:ok, envelope} = Export.run(:all, actor: actor)

      assert envelope["records"] ==
               envelope |> Jason.encode!() |> Jason.decode!() |> Map.fetch!("records")
    end

    test "no block carries an atom key or an atom type", %{actor: actor} do
      {:ok, envelope} = Export.run([:post], actor: actor)

      for block <- record(envelope, "exportable")["blocks"] do
        assert is_binary(block["type"])
        assert Enum.all?(Map.keys(block), &is_binary/1)
        assert Enum.all?(Map.keys(block["value"] || %{}), &is_binary/1)
      end
    end

    test "nil fields are omitted rather than carried as null", %{actor: actor} do
      {:ok, envelope} = Export.run([:page], actor: actor)
      refute Map.has_key?(record(envelope, "a-draft"), "canonical_url")
    end

    test "encodes to JSON", %{actor: actor} do
      {:ok, json} = Export.to_json([:post], actor: actor)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["records"] |> length() == 1
    end
  end

  describe "filters" do
    test "only the named types are exported", %{actor: actor} do
      {:ok, envelope} = Export.run([:post], actor: actor)
      assert Enum.map(envelope["records"], & &1["type"]) |> Enum.uniq() == ["post"]
    end

    test "states restrict what is included", %{actor: actor} do
      {:ok, envelope} = Export.run(:all, actor: actor, states: [:published])
      assert envelope["records"] == []

      {:ok, all} = Export.run(:all, actor: actor, states: [:draft])
      assert length(all["records"]) == 2
    end

    test "limit caps the records per type", %{actor: actor} do
      {:ok, envelope} = Export.run(:all, actor: actor, limit: 1)
      # One post and one page — the limit is per type, not per envelope.
      assert length(envelope["records"]) == 2
    end
  end

  describe "round trip" do
    test "an export loads back into an empty target", %{actor: actor} do
      {:ok, envelope} = Export.run(:all, actor: actor)

      # A second organization would be the honest target, but multi-tenancy is
      # not the subject here — purging and re-importing exercises the same
      # path: the envelope must stand alone. `purge`, not `destroy` — see the
      # trashed-slug test below for why that distinction matters.
      for post <- CMS.list_posts!(actor: actor), do: CMS.purge_post!(post, actor: actor)
      for page <- CMS.list_pages!(actor: actor), do: CMS.purge_page!(page, actor: actor)

      {:ok, report} = Import.run_envelope(envelope, actor: actor, skip_media: true)

      assert length(report.created) == 2

      reloaded = CMS.list_posts!(actor: actor, load: [:tags, :category]) |> List.first()
      assert reloaded.title == "Exportable"
      assert reloaded.excerpt == "A summary."
      assert reloaded.category.slug == "news"
      assert Enum.map(reloaded.tags, & &1.slug) == ["guides"]
      assert Enum.map(reloaded.blocks, & &1.type) == [:rich_text, :heading]
    end

    # `destroy` is a SOFT delete: the row and its `[slug, locale]` unique index
    # survive while the ordinary read hides it. Reporting that as importable
    # would produce a raw "slug has already been taken" from the database with
    # nothing to point the operator at.
    test "a slug held by a TRASHED record is reported, not attempted", %{actor: actor} do
      {:ok, envelope} = Export.run(:all, actor: actor)

      for post <- CMS.list_posts!(actor: actor), do: CMS.destroy_post!(post, actor: actor)
      for page <- CMS.list_pages!(actor: actor), do: CMS.destroy_page!(page, actor: actor)

      {:ok, report} = Import.run_envelope(envelope, actor: actor, skip_media: true)

      assert report.created == []
      assert length(report.failed) == 2
      assert Enum.all?(report.failed, &(&1.reason == :slug_held_by_trashed_record))
    end

    test "a dry run reports the trashed collision too", %{actor: actor} do
      {:ok, envelope} = Export.run(:all, actor: actor)
      for post <- CMS.list_posts!(actor: actor), do: CMS.destroy_post!(post, actor: actor)

      {:ok, report} =
        Import.run_envelope(envelope, actor: actor, skip_media: true, dry_run: true)

      assert Enum.any?(report.failed, &(&1.reason == :slug_held_by_trashed_record))
    end

    test "re-importing into the same site skips rather than duplicating", %{actor: actor} do
      {:ok, envelope} = Export.run(:all, actor: actor)
      {:ok, report} = Import.run_envelope(envelope, actor: actor, skip_media: true)

      assert report.created == []
      assert length(report.skipped) == 2
      assert length(CMS.list_posts!(actor: actor)) == 1
    end
  end

  describe "media manifest" do
    setup %{actor: actor} do
      {:ok, item} =
        CMS.create_media_item(
          %{
            filename: "pic.jpg",
            content_type: "image/jpeg",
            storage_key: "k/pic.jpg",
            url: "https://cdn.example.com/pic.jpg",
            alt: "A picture"
          },
          actor: actor
        )

      {:ok, post} =
        CMS.create_post(
          %{
            title: "With media",
            slug: "with-media",
            featured_image_id: item.id,
            block_tree: [%{"_type" => "image", "url" => item.url, "media_id" => item.id}]
          },
          actor: actor
        )

      %{item: item, post: post}
    end

    # This read used to be `authorize?: false` with NO tenant. Under strict
    # tenancy (the production default) that raises and a rescue turned the
    # manifest into [] — silently losing every featured image on every round
    # trip — while a fail-open build leaked media across orgs and past policy.
    test "carries the media a record references", %{actor: actor, item: item} do
      {:ok, envelope} = Export.run(:all, actor: actor)

      assert [entry] = envelope["media"]
      assert entry["id"] == item.id
      assert entry["url"] == "https://cdn.example.com/pic.jpg"
      assert entry["alt"] == "A picture"
    end

    test "a nested media_id is remapped on import, not left dangling", %{actor: actor, item: item} do
      {:ok, envelope} = Export.run(:all, actor: actor)

      # A gallery carries its media_ids inside a list of maps — deeper than the
      # top-level image block the remapper used to handle.
      envelope =
        put_in(envelope, ["records"], [
          %{
            "type" => "page",
            "title" => "Gallery page",
            "slug" => "gallery-page",
            "blocks" => [
              %{
                "type" => "gallery",
                "value" => %{"images" => [%{"media_id" => item.id, "url" => "https://old/x.jpg"}]}
              }
            ]
          }
        ])

      {:ok, report} = Import.run_envelope(envelope, actor: actor, skip_media: true)
      assert report.failed == []

      page = CMS.list_pages!(actor: actor) |> Enum.find(&(&1.slug == "gallery-page"))
      [gallery] = page.blocks

      # The source uuid must be gone — it names a row the target has no copy of.
      assert [image] = gallery.value.images
      refute image["media_id"] == item.id
      assert image["url"] == "https://cdn.example.com/pic.jpg"
    end
  end

  describe "authorization" do
    test "an export reads under the actor's own policies", %{actor: admin} do
      viewer = user(:viewer)

      {:ok, as_admin} = Export.run(:all, actor: admin)
      {:ok, as_viewer} = Export.run(:all, actor: viewer)

      assert length(as_admin["records"]) == 2
      # Whatever the viewer can read, it must not be MORE than the admin — an
      # export must never be a way around authorization.
      assert length(as_viewer["records"]) <= length(as_admin["records"])
    end
  end
end
