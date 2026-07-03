defmodule Kiln.FieldTypesTest do
  @moduledoc """
  The custom-field-type registry (D18), proven through the fixture plugin's
  `Rating` type: it registers alongside the core types, admins can define
  fields with it, and `ApplyCustomFields` dispatches content writes through
  the plugin's `cast/2` — no core edits.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FieldTypes
  alias KilnCMS.FixturePlugin.FieldTypes.Rating

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "ft-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "ft-#{System.unique_integer([:positive])}"

  defp define_rating!(actor, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :page,
          name: "quality_#{System.unique_integer([:positive])}",
          label: "Quality",
          field_type: :rating
        },
        attrs
      ),
      actor: actor
    )
  end

  test "the plugin type registers next to the core types" do
    assert :rating in FieldDefinition.field_types()
    assert :string in FieldDefinition.field_types()
    assert FieldTypes.get(:rating) == Rating
    # Core types have no plugin module.
    assert FieldTypes.get(:string) == nil
    # Contract defaults derived from the module name.
    assert Rating.name() == :rating
    assert Rating.label() == "Rating"
  end

  test "definitions accept registered types and reject unregistered atoms" do
    actor = admin()

    assert define_rating!(actor)

    assert {:error, error} =
             CMS.create_field_definition(
               %{content_type: :page, name: "bogus_field", label: "B", field_type: :bogus},
               actor: actor
             )

    assert Exception.message(error) =~ "is not a registered field type"
  end

  test "content writes coerce through the plugin's cast/2" do
    actor = admin()
    definition = define_rating!(actor)

    page =
      CMS.create_page!(
        %{title: "Rated", slug: slug(), custom_fields: %{definition.name => "4"}},
        actor: actor
      )

    assert page.custom_fields == %{definition.name => 4}
  end

  test "the plugin's validation message reaches the write error" do
    actor = admin()
    definition = define_rating!(actor)

    assert {:error, error} =
             CMS.create_page(
               %{title: "Over", slug: slug(), custom_fields: %{definition.name => "9"}},
               actor: actor
             )

    assert Exception.message(error) =~ "must be a rating from 1 to 5"
  end

  test "blank handling stays the host's job: optional skips, required errors" do
    actor = admin()
    optional = define_rating!(actor)

    page = CMS.create_page!(%{title: "Unrated", slug: slug()}, actor: actor)
    refute Map.has_key?(page.custom_fields, optional.name)

    required = define_rating!(actor, %{required: true})

    assert {:error, error} = CMS.create_page(%{title: "Must", slug: slug()}, actor: actor)
    assert Exception.message(error) =~ "(#{required.name}) is required"
  end
end
