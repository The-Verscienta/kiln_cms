defmodule KilnCMS.CMS.GeolocationFieldTest do
  @moduledoc """
  The built-in geolocation field type (#428): a composite custom field that
  registers through `Kiln.FieldType` like a plugin's, stores a structured
  lat/lng value, and fires as schema.org `GeoCoordinates`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FieldTypes
  alias KilnCMS.Firing

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "geo-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "geo-#{System.unique_integer([:positive])}"

  defp define!(actor, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :page,
          name: "clinic_#{System.unique_integer([:positive])}",
          label: "Clinic location",
          field_type: :geolocation
        },
        attrs
      ),
      actor: actor
    )
  end

  describe "registration" do
    test "it registers as a field type without being a core one" do
      assert :geolocation in FieldDefinition.field_types()
      refute :geolocation in FieldTypes.core()
      assert FieldTypes.get(:geolocation) == KilnCMS.CMS.FieldTypes.Geolocation
      assert :geolocation in FieldTypes.reserved()
    end

    test "it declares composite input parts for the editor" do
      module = FieldTypes.get(:geolocation)

      assert Enum.map(module.input_parts(%{}), & &1.key) == ["lat", "lng", "label", "zoom"]
    end
  end

  describe "casting" do
    test "the editor's part map stores floats" do
      actor = admin()
      definition = define!(actor)

      page =
        CMS.create_page!(
          %{
            title: "Clinic",
            slug: slug(),
            custom_fields: %{
              definition.name => %{"lat" => "51.5074", "lng" => "-0.1278", "zoom" => "12"}
            }
          },
          actor: actor
        )

      assert page.custom_fields[definition.name] == %{
               "lat" => 51.5074,
               "lng" => -0.1278,
               "zoom" => 12
             }
    end

    test "a \"lat,lng\" string is accepted, which is what a default must be" do
      actor = admin()
      definition = define!(actor, %{default: "48.8584, 2.2945"})

      page = CMS.create_page!(%{title: "Tower", slug: slug()}, actor: actor)

      assert page.custom_fields[definition.name] == %{"lat" => 48.8584, "lng" => 2.2945}
    end

    test "an optional label is trimmed and kept; blank optionals drop out" do
      actor = admin()
      definition = define!(actor)

      page =
        CMS.create_page!(
          %{
            title: "Clinic",
            slug: slug(),
            custom_fields: %{
              definition.name => %{
                "lat" => "51.5",
                "lng" => "-0.1",
                "label" => "  London  ",
                "zoom" => ""
              }
            }
          },
          actor: actor
        )

      assert page.custom_fields[definition.name] == %{
               "lat" => 51.5,
               "lng" => -0.1,
               "label" => "London"
             }
    end

    test "out-of-range coordinates are rejected by axis" do
      actor = admin()
      definition = define!(actor)

      assert {:error, error} =
               CMS.create_page(
                 %{
                   title: "Nowhere",
                   slug: slug(),
                   custom_fields: %{definition.name => %{"lat" => "120", "lng" => "0"}}
                 },
                 actor: actor
               )

      assert Exception.message(error) =~ "latitude must be between -90 and 90"

      assert {:error, error} =
               CMS.create_page(
                 %{
                   title: "Nowhere",
                   slug: slug(),
                   custom_fields: %{definition.name => %{"lat" => "0", "lng" => "200"}}
                 },
                 actor: actor
               )

      assert Exception.message(error) =~ "longitude must be between -180 and 180"
    end

    test "a half-filled pair is an error, not a silent half-value" do
      actor = admin()
      definition = define!(actor)

      assert {:error, error} =
               CMS.create_page(
                 %{
                   title: "Half",
                   slug: slug(),
                   custom_fields: %{definition.name => %{"lat" => "51.5", "lng" => ""}}
                 },
                 actor: actor
               )

      assert Exception.message(error) =~ "must be a latitude and longitude"
    end

    test "an untouched composite widget submits blanks and counts as empty" do
      actor = admin()
      optional = define!(actor)
      blank = %{"lat" => "", "lng" => "", "label" => "", "zoom" => ""}

      page =
        CMS.create_page!(
          %{title: "Empty", slug: slug(), custom_fields: %{optional.name => blank}},
          actor: actor
        )

      refute Map.has_key?(page.custom_fields, optional.name)

      required = define!(actor, %{required: true})

      assert {:error, error} =
               CMS.create_page(
                 %{title: "Empty", slug: slug(), custom_fields: %{required.name => blank}},
                 actor: actor
               )

      assert Exception.message(error) =~ "(#{required.name}) is required"
    end

    test "a stored value round-trips through an API-style write" do
      actor = admin()
      definition = define!(actor)
      stored = %{"lat" => 51.5, "lng" => -0.1, "label" => "London"}

      page =
        CMS.create_page!(
          %{title: "Round trip", slug: slug(), custom_fields: %{definition.name => stored}},
          actor: actor
        )

      assert page.custom_fields[definition.name] == stored
    end
  end

  describe "firing" do
    test "a geolocation field fires as a Place with GeoCoordinates" do
      actor = admin()
      definition = define!(actor)

      page =
        CMS.create_page!(
          %{
            title: "Clinic",
            slug: slug(),
            custom_fields: %{
              definition.name => %{"lat" => "51.5074", "lng" => "-0.1278", "label" => "London"}
            }
          },
          actor: actor
        )

      {:ok, %{json_ld: json_ld, json: json}} = Firing.Engine.fire(page, mode: :preview)

      [main | _] = json_ld["@graph"]

      assert main["contentLocation"] == %{
               "@type" => "Place",
               "name" => "London",
               "geo" => %{
                 "@type" => "GeoCoordinates",
                 "latitude" => 51.5074,
                 "longitude" => -0.1278
               }
             }

      # The value is on the json surface too, so a headless consumer reading
      # the fired artifact sees the same custom fields the APIs serve.
      assert json["custom_fields"][definition.name]["lat"] == 51.5074
    end

    test "the place falls back to the field's label when the value has none" do
      actor = admin()
      definition = define!(actor, %{label: "Trial site"})

      page =
        CMS.create_page!(
          %{
            title: "Site",
            slug: slug(),
            custom_fields: %{definition.name => %{"lat" => "1.5", "lng" => "2.5"}}
          },
          actor: actor
        )

      {:ok, %{json_ld: json_ld}} = Firing.Engine.fire(page, mode: :preview)
      [main | _] = json_ld["@graph"]

      assert main["contentLocation"]["name"] == "Trial site"
    end

    test "two geolocation fields fire as a list; none fires no key at all" do
      actor = admin()
      first = define!(actor, %{label: "Clinic"})
      second = define!(actor, %{label: "Warehouse"})

      page =
        CMS.create_page!(
          %{
            title: "Both",
            slug: slug(),
            custom_fields: %{
              first.name => %{"lat" => "1", "lng" => "2"},
              second.name => %{"lat" => "3", "lng" => "4"}
            }
          },
          actor: actor
        )

      {:ok, %{json_ld: json_ld}} = Firing.Engine.fire(page, mode: :preview)
      [main | _] = json_ld["@graph"]

      assert [%{"name" => _}, %{"name" => _}] = main["contentLocation"]

      plain = CMS.create_page!(%{title: "Plain", slug: slug()}, actor: actor)
      {:ok, %{json_ld: plain_json_ld}} = Firing.Engine.fire(plain, mode: :preview)
      [plain_main | _] = plain_json_ld["@graph"]

      refute Map.has_key?(plain_main, "contentLocation")
    end
  end
end
