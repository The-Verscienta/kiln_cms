defmodule KilnCMS.Media.SnapshotTest do
  @moduledoc """
  The delivered media shape (`KilnCMS.Media.Snapshot`): what a `:media` custom
  field stores, what the fired `:json` artifact carries for it and for
  `image`/`gallery` blocks, how both catch up once the variant worker has run,
  and `mix kiln.media.resnapshot`.

  `async: false`: it fires and re-fires on the default org, through Oban.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.CMS
  alias KilnCMS.Firing.Engine
  alias KilnCMS.Media
  alias KilnCMS.Media.{Resnapshot, Snapshot}

  @variants %{
    "card" => %{
      "url" => "/uploads/card.jpg",
      "width" => 800,
      "height" => 450,
      "content_type" => "image/jpeg",
      "bytes" => 5000
    },
    "medium" => %{
      "url" => "/uploads/medium.jpg",
      "width" => 1024,
      "height" => 576,
      "content_type" => "image/jpeg",
      "bytes" => 9000
    },
    "thumb.webp" => %{
      "url" => "/uploads/thumb.webp",
      "width" => 400,
      "height" => 225,
      "content_type" => "image/webp",
      "bytes" => 700
    },
    "thumb" => %{
      "url" => "/uploads/thumb.jpg",
      "width" => 400,
      "height" => 225,
      "content_type" => "image/jpeg"
    }
  }

  setup do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "snap-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    n = System.unique_integer([:positive])
    hero = "hero#{n}"
    shots = "shots#{n}"

    for {name, multiple} <- [{hero, false}, {shots, true}] do
      CMS.create_field_definition!(
        %{content_type: :page, name: name, label: name, field_type: :media, multiple: multiple},
        actor: actor
      )
    end

    %{actor: actor, org_id: KilnCMS.Accounts.default_org_id(), hero: hero, shots: shots}
  end

  defp image!(org_id, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.CMS.MediaItem,
      Map.merge(
        %{
          org_id: org_id,
          filename: "kiln-#{System.unique_integer([:positive])}.jpg",
          url: "/uploads/orig-#{System.unique_integer([:positive])}.jpg",
          alt: "The kiln at dusk",
          content_type: "image/jpeg"
        },
        attrs
      )
    )
  end

  # What `Media.VariantWorker` records once it has derived the variants.
  defp process!(item) do
    CMS.record_media_processing!(item, %{width: 1600, height: 900, variants: @variants},
      actor: Media.system(),
      tenant: item.org_id
    )
  end

  defp publish!(ctx, attrs) do
    page =
      CMS.create_page!(
        Map.merge(
          %{title: "Snapshots", slug: "snap-#{System.unique_integer([:positive])}"},
          attrs
        ),
        actor: ctx.actor
      )

    page = CMS.publish_page!(page, %{}, actor: ctx.actor)
    drain_oban()
    page
  end

  defp artifact(page) do
    {:ok, %{"custom_fields" => _} = body} = Engine.read(page.org_id, :page, page.id, :json)
    body
  end

  defp reload(page), do: CMS.get_page!(page.id, actor: nil, authorize?: false)

  describe "of/1" do
    test "dimensions, MIME type, focal point, and variants smallest first with crops last",
         %{org_id: org_id} do
      item = org_id |> image!(%{focal_x: 0.25, focal_y: 0.75}) |> process!()

      assert %{
               "id" => id,
               "url" => url,
               "alt" => "The kiln at dusk",
               "width" => 1600,
               "height" => 900,
               "mime_type" => "image/jpeg",
               "focal" => %{"x" => 0.25, "y" => 0.75},
               "variants" => variants
             } = Snapshot.of(item)

      assert {id, url} == {item.id, item.url}

      assert Enum.map(variants, &{&1["label"], &1["cropped"]}) == [
               {"thumb", false},
               {"thumb.webp", false},
               {"medium", false},
               {"card", true}
             ]

      assert %{
               "label" => "thumb.webp",
               "width" => 400,
               "height" => 225,
               "format" => "image/webp",
               "url" => "/uploads/thumb.webp",
               "bytes" => 700
             } = Enum.at(variants, 1)

      # A variant recorded before sizes were: `bytes` is null, not absent.
      assert %{"label" => "thumb", "bytes" => nil} = hd(variants)
    end

    test "a crop's alternate encoding is a crop too; a document has no focal point",
         %{org_id: org_id} do
      item =
        CMS.record_media_processing!(
          image!(org_id),
          %{variants: %{"card.webp" => %{"url" => "/u/card.webp", "width" => 800}}},
          actor: Media.system(),
          tenant: org_id
        )

      assert [%{"label" => "card.webp", "cropped" => true}] = Snapshot.of(item)["variants"]

      pdf = image!(org_id, %{content_type: "application/pdf", url: "/uploads/doc.pdf"})

      assert %{"focal" => nil, "variants" => [], "mime_type" => "application/pdf"} =
               Snapshot.of(pdf)
    end
  end

  describe "before and after variants exist" do
    test "the snapshot holds what exists; the artifact catches up when processing lands",
         %{org_id: org_id, hero: hero, shots: shots} = ctx do
      [a, b] = for _ <- 1..2, do: image!(org_id)

      page = publish!(ctx, %{custom_fields: %{hero => a.id, shots => [b.id, a.id]}})

      assert %{"variants" => [], "width" => nil} = page.custom_fields[hero]
      assert %{"variants" => []} = artifact(page)["custom_fields"][hero]

      # The variant worker's write re-fires the published referrer.
      a = process!(a)
      drain_oban()

      fired = artifact(page)["custom_fields"]
      assert fired[hero] == Snapshot.of(a)
      assert Enum.map(fired[shots], & &1["id"]) == [b.id, a.id]
      assert Enum.at(fired[shots], 1) == Snapshot.of(a)
      assert %{"variants" => []} = Enum.at(fired[shots], 0)

      # The stored value is the write-time one until a save or a resnapshot.
      assert %{"variants" => []} = reload(page).custom_fields[hero]
    end

    test "moving the focal point re-fires the referrer with the new point",
         %{actor: actor, org_id: org_id, hero: hero} = ctx do
      item = org_id |> image!() |> process!()
      page = publish!(ctx, %{custom_fields: %{hero => item.id}})
      assert artifact(page)["custom_fields"][hero]["focal"] == %{"x" => 0.5, "y" => 0.5}

      CMS.update_media_item_metadata!(item, %{focal_x: 0.1, focal_y: 0.9}, actor: actor)
      drain_oban()

      assert artifact(page)["custom_fields"][hero]["focal"] == %{"x" => 0.1, "y" => 0.9}
    end
  end

  describe "blocks in the fired :json artifact" do
    test "image blocks and gallery images carry the same shape, nested ones too",
         %{org_id: org_id} = ctx do
      [a, b] = for _ <- 1..2, do: org_id |> image!() |> process!()

      page =
        publish!(ctx, %{
          blocks: [
            %{"_type" => "image", "media_id" => a.id, "url" => a.url, "alt" => "Placed"},
            %{"_type" => "image", "url" => "https://example.com/pasted.jpg", "alt" => "Pasted"},
            %{
              "_type" => "gallery",
              "images" => [%{"media_id" => b.id, "url" => b.url, "alt" => "Shot"}]
            },
            %{
              "_type" => "columns",
              "layout" => "1-1",
              "columns" => [
                %{"blocks" => [%{"_type" => "heading", "text" => "Left"}]},
                %{
                  "blocks" => [
                    %{"_type" => "image", "media_id" => b.id, "url" => b.url, "alt" => "Nested"}
                  ]
                }
              ]
            }
          ]
        })

      [placed, pasted, gallery, columns] = artifact(page)["blocks"]

      assert placed["media"] == Snapshot.of(a)
      # The block's own alt is untouched beside it.
      assert placed["alt"] == "Placed"
      assert pasted["media"] == nil
      assert [%{"media" => media}] = gallery["images"]
      assert media == Snapshot.of(b)

      assert [%{"blocks" => [heading]}, %{"blocks" => [nested]}] = columns["columns"]
      refute Map.has_key?(heading, "media")
      assert nested["media"] == Snapshot.of(b)
    end
  end

  describe "Resnapshot" do
    test "a dry run reports, a real run writes through the action, a second run writes nothing",
         %{org_id: org_id, hero: hero, shots: shots} = ctx do
      [a, b] = for _ <- 1..2, do: image!(org_id)
      page = publish!(ctx, %{custom_fields: %{hero => a.id, shots => [b.id]}})
      # An untouched record, and one with no media values, are not stale.
      _bare = publish!(ctx, %{})

      [a, b] = Enum.map([a, b], &process!/1)
      before = reload(page)

      dry = Resnapshot.run(org_id, dry_run?: true)
      assert dry.stale >= 1
      assert dry.written == 0
      assert reload(page).custom_fields == before.custom_fields

      report = Resnapshot.run(org_id)
      assert report.written == dry.stale
      assert report.failed == []

      after_run = reload(page)
      assert after_run.custom_fields[hero] == Snapshot.of(a)
      assert after_run.custom_fields[shots] == [Snapshot.of(b)]
      # A background pass, not an edit.
      assert after_run.updated_at == before.updated_at
      assert after_run.lock_version == before.lock_version

      assert %{stale: 0, written: 0} = Resnapshot.run(org_id)
    end

    test "the action's system grant is the :media pipeline's alone",
         %{org_id: org_id, hero: hero} = ctx do
      page = publish!(ctx, %{custom_fields: %{hero => image!(org_id).id}})

      resnapshot = fn actor ->
        page
        |> Ash.Changeset.for_update(:resnapshot_media, %{}, actor: actor, tenant: org_id)
        |> Ash.update()
      end

      assert {:ok, _page} = resnapshot.(Media.system())
      assert {:error, %Ash.Error.Forbidden{}} = resnapshot.(nil)

      assert {:error, %Ash.Error.Forbidden{}} =
               resnapshot.(KilnCMS.SystemActor.new(:computed_fields))
    end

    test "the mix task is a dry run unless --apply", %{org_id: org_id, hero: hero} = ctx do
      item = image!(org_id)
      page = publish!(ctx, %{custom_fields: %{hero => item.id}})
      item = process!(item)

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      capture_io(fn -> Mix.Tasks.Kiln.Media.Resnapshot.run(["--org", org_id]) end)
      assert_received {:mix_shell, :info, [dry]}
      assert dry =~ "would re-snapshot"
      assert dry =~ "--apply"
      assert %{"variants" => []} = reload(page).custom_fields[hero]

      capture_io(fn -> Mix.Tasks.Kiln.Media.Resnapshot.run(["--org", org_id, "--apply"]) end)
      assert_received {:mix_shell, :info, [applied]}
      assert applied =~ "re-snapshotted"
      assert reload(page).custom_fields[hero] == Snapshot.of(item)
    end
  end
end
