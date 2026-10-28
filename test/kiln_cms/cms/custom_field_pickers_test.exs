defmodule KilnCMS.CMS.CustomFieldPickersTest do
  @moduledoc """
  Phase 5 (decision D17): `:media` and `:reference` custom field types. Values
  are resolved at write time into snapshot maps (media: `KilnCMS.Media.Snapshot`;
  reference: id/type/slug/title), so delivery needs no extra lookups.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cfp-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define_type!(actor) do
    CMS.create_type_definition!(
      %{name: "pk#{System.unique_integer([:positive])}", label: "Picker"},
      actor: actor
    )
  end

  defp media! do
    Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
      filename: "hero-#{System.unique_integer([:positive])}.png",
      url: "/uploads/hero.png",
      alt: "A hero image"
    })
  end

  defp slug, do: "pk-#{System.unique_integer([:positive])}"

  describe "definition validation" do
    test "a reference field requires a known target type" do
      actor = admin()
      definition = define_type!(actor)

      base = %{type_definition_id: definition.id, name: "rel", label: "Rel"}

      assert {:error, _} =
               CMS.create_field_definition(Map.put(base, :field_type, :reference), actor: actor)

      assert {:error, _} =
               CMS.create_field_definition(
                 base |> Map.put(:field_type, :reference) |> Map.put(:target_type, "nonsense"),
                 actor: actor
               )

      # Compiled and dynamic targets both validate.
      assert CMS.create_field_definition!(
               base |> Map.put(:field_type, :reference) |> Map.put(:target_type, "page"),
               actor: actor
             )

      other = define_type!(actor)

      assert CMS.create_field_definition!(
               %{
                 type_definition_id: definition.id,
                 name: "sibling",
                 label: "Sibling",
                 field_type: :reference,
                 target_type: other.name
               },
               actor: actor
             )
    end
  end

  describe "media fields" do
    test "an id is snapshotted to the delivered media shape; unknown ids error" do
      actor = admin()
      definition = define_type!(actor)
      media = media!()

      CMS.create_field_definition!(
        %{type_definition_id: definition.id, name: "hero", label: "Hero", field_type: :media},
        actor: actor
      )

      entry =
        ContentTypes.create!(
          definition.name,
          %{title: "With hero", slug: slug(), custom_fields: %{"hero" => media.id}},
          actor: actor
        )

      # Not processed yet: no dimensions, no variants — what exists now.
      assert entry.custom_fields == %{
               "hero" => %{
                 "id" => media.id,
                 "url" => media.url,
                 "alt" => media.alt,
                 "width" => nil,
                 "height" => nil,
                 "mime_type" => nil,
                 "focal" => %{"x" => 0.5, "y" => 0.5},
                 "variants" => []
               }
             }

      # Round-tripping the stored map re-resolves by its id.
      {:ok, entry} =
        CMS.update_entry(entry, %{custom_fields: entry.custom_fields}, actor: actor)

      assert entry.custom_fields["hero"]["id"] == media.id

      assert_raise Ash.Error.Invalid, fn ->
        ContentTypes.create!(
          definition.name,
          %{title: "Bad", slug: slug(), custom_fields: %{"hero" => Ash.UUID.generate()}},
          actor: actor
        )
      end
    end
  end

  describe "media gallery fields (multiple: true)" do
    setup do
      actor = admin()
      definition = define_type!(actor)

      field =
        CMS.create_field_definition!(
          %{
            type_definition_id: definition.id,
            name: "shots",
            label: "Shots",
            field_type: :media,
            multiple: true
          },
          actor: actor
        )

      %{actor: actor, definition: definition, field: field}
    end

    defp snapshot(media), do: KilnCMS.Media.Snapshot.of(media)

    test "a list of ids is snapshotted in order, blanks dropped and repeats kept once", %{
      actor: actor,
      definition: definition
    } do
      [a, b, c] = for _ <- 1..3, do: media!()

      entry =
        ContentTypes.create!(
          definition.name,
          %{
            title: "Gallery",
            slug: slug(),
            custom_fields: %{"shots" => ["", c.id, a.id, c.id, b.id]}
          },
          actor: actor
        )

      assert entry.custom_fields["shots"] == [snapshot(c), snapshot(a), snapshot(b)]

      # The stored list round-trips; a lone id is a one-image gallery.
      {:ok, entry} = CMS.update_entry(entry, %{custom_fields: entry.custom_fields}, actor: actor)
      assert Enum.map(entry.custom_fields["shots"], & &1["id"]) == [c.id, a.id, b.id]

      {:ok, entry} = CMS.update_entry(entry, %{custom_fields: %{"shots" => a.id}}, actor: actor)
      assert entry.custom_fields["shots"] == [snapshot(a)]

      # The editor's leading blank alone is an emptied gallery: the key clears.
      {:ok, entry} = CMS.update_entry(entry, %{custom_fields: %{"shots" => [""]}}, actor: actor)
      refute Map.has_key?(entry.custom_fields, "shots")
    end

    test "one unknown id fails the whole field", %{actor: actor, definition: definition} do
      media = media!()

      error =
        assert_raise Ash.Error.Invalid, fn ->
          ContentTypes.create!(
            definition.name,
            %{
              title: "Bad",
              slug: slug(),
              custom_fields: %{"shots" => [media.id, Ash.UUID.generate()]}
            },
            actor: actor
          )
        end

      assert Exception.message(error) =~ "is not an existing media item"
    end

    test "the error names the image that no longer resolves", %{
      actor: actor,
      definition: definition
    } do
      media = media!()
      gone = Ash.UUID.generate()

      error =
        assert_raise Ash.Error.Invalid, fn ->
          ContentTypes.create!(
            definition.name,
            %{title: "Gone", slug: slug(), custom_fields: %{"shots" => [media.id, gone]}},
            actor: actor
          )
        end

      assert Exception.message(error) =~ "image 2 (#{gone}) is not an existing media item"
    end

    test "a required gallery refuses an empty list", %{
      actor: actor,
      definition: definition,
      field: field
    } do
      CMS.update_field_definition!(field, %{required: true}, actor: actor)

      error =
        assert_raise Ash.Error.Invalid, fn ->
          ContentTypes.create!(
            definition.name,
            %{title: "Empty", slug: slug(), custom_fields: %{"shots" => [""]}},
            actor: actor
          )
        end

      assert Exception.message(error) =~ "is required"
    end

    test "every gallery image is a media usage edge", %{actor: actor, definition: definition} do
      [a, b] = for _ <- 1..2, do: media!()

      entry =
        ContentTypes.create!(
          definition.name,
          %{title: "Used", slug: slug(), custom_fields: %{"shots" => [a.id, b.id]}},
          actor: actor
        )

      refs = KilnCMS.Firing.References.document_refs(entry)
      assert {:media, a.id} in refs
      assert {:media, b.id} in refs
    end

    test "flipping the flag reshapes the stored values", %{
      actor: actor,
      definition: definition,
      field: field
    } do
      [a, b] = for _ <- 1..2, do: media!()

      gallery =
        ContentTypes.create!(
          definition.name,
          %{title: "Two", slug: slug(), custom_fields: %{"shots" => [a.id, b.id]}},
          actor: actor
        )

      empty =
        ContentTypes.create!(definition.name, %{title: "None", slug: slug()}, actor: actor)

      # Gallery -> single keeps the first image.
      field = CMS.update_field_definition!(field, %{multiple: false}, actor: actor)
      assert CMS.get_entry!(gallery.id, actor: actor).custom_fields["shots"] == snapshot(a)
      assert CMS.get_entry!(empty.id, actor: actor).custom_fields == %{}

      # Single -> gallery wraps it, losslessly.
      CMS.update_field_definition!(field, %{multiple: true}, actor: actor)
      assert CMS.get_entry!(gallery.id, actor: actor).custom_fields["shots"] == [snapshot(a)]
    end

    test "the flag only sticks to a media field; retyping a gallery narrows it", %{
      actor: actor,
      definition: definition,
      field: field
    } do
      [a, b] = for _ <- 1..2, do: media!()

      entry =
        ContentTypes.create!(
          definition.name,
          %{title: "Retype", slug: slug(), custom_fields: %{"shots" => [a.id, b.id]}},
          actor: actor
        )

      field = CMS.update_field_definition!(field, %{field_type: :url}, actor: actor)
      refute field.multiple

      # No list left under a field that is no longer a gallery.
      assert CMS.get_entry!(entry.id, actor: actor).custom_fields["shots"] == snapshot(a)
    end

    test "a single media field handed a gallery list keeps its first item", %{
      actor: actor,
      definition: definition
    } do
      [a, b] = for _ <- 1..2, do: media!()

      CMS.create_field_definition!(
        %{type_definition_id: definition.id, name: "hero", label: "Hero", field_type: :media},
        actor: actor
      )

      # A value stored while the field was a gallery — a working copy, a
      # version, an API round-trip — still writes, as the narrowing would.
      entry =
        ContentTypes.create!(
          definition.name,
          %{title: "Stale", slug: slug(), custom_fields: %{"hero" => ["", a.id, b.id]}},
          actor: actor
        )

      assert entry.custom_fields["hero"] == snapshot(a)
    end

    test "on a compiled type, a rename and a flip in one edit reshape under the new key", %{
      actor: actor
    } do
      [a, b] = for _ <- 1..2, do: media!()
      name = "pk_shots_#{System.unique_integer([:positive])}"

      field =
        CMS.create_field_definition!(
          %{content_type: :page, name: name, label: "Shots", field_type: :media, multiple: true},
          actor: actor
        )

      page =
        CMS.create_page!(
          %{title: "Gallery page", slug: slug(), custom_fields: %{name => [a.id, b.id]}},
          actor: actor
        )

      renamed = name <> "_hero"

      CMS.update_field_definition!(field, %{name: renamed, multiple: false}, actor: actor)

      assert CMS.get_page!(page.id, actor: actor).custom_fields == %{renamed => snapshot(a)}
    end
  end

  describe "reference fields" do
    test "a target id is snapshotted to %{id, type, slug, title}; unknown ids error" do
      actor = admin()
      definition = define_type!(actor)
      page = CMS.create_page!(%{title: "Target page", slug: slug()}, actor: actor)

      CMS.create_field_definition!(
        %{
          type_definition_id: definition.id,
          name: "related_page",
          label: "Related page",
          field_type: :reference,
          target_type: "page"
        },
        actor: actor
      )

      entry =
        ContentTypes.create!(
          definition.name,
          %{title: "Refers", slug: slug(), custom_fields: %{"related_page" => page.id}},
          actor: actor
        )

      assert entry.custom_fields == %{
               "related_page" => %{
                 "id" => page.id,
                 "type" => "page",
                 "slug" => page.slug,
                 "title" => "Target page"
               }
             }

      assert_raise Ash.Error.Invalid, fn ->
        ContentTypes.create!(
          definition.name,
          %{title: "Bad", slug: slug(), custom_fields: %{"related_page" => Ash.UUID.generate()}},
          actor: actor
        )
      end
    end

    test "references can target another dynamic type" do
      actor = admin()
      recipes = define_type!(actor)
      guides = define_type!(actor)

      guide = ContentTypes.create!(guides.name, %{title: "Guide", slug: slug()}, actor: actor)

      CMS.create_field_definition!(
        %{
          type_definition_id: recipes.id,
          name: "guide",
          label: "Guide",
          field_type: :reference,
          target_type: guides.name
        },
        actor: actor
      )

      entry =
        ContentTypes.create!(
          recipes.name,
          %{title: "Linked", slug: slug(), custom_fields: %{"guide" => guide.id}},
          actor: actor
        )

      assert entry.custom_fields["guide"]["type"] == guides.name
      assert entry.custom_fields["guide"]["title"] == "Guide"
    end
  end
end
