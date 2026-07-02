defmodule KilnCMS.CMS.CustomFieldPickersTest do
  @moduledoc """
  Phase 5 (decision D17): `:media` and `:reference` custom field types. Values
  are resolved at write time into small snapshot maps (media: id/url/alt;
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
    test "an id is snapshotted to %{id, url, alt}; unknown ids error" do
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

      assert entry.custom_fields == %{
               "hero" => %{"id" => media.id, "url" => media.url, "alt" => media.alt}
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
