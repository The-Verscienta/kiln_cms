defmodule KilnCMS.CMS.CustomFieldsTest do
  @moduledoc """
  Coverage for admin-UI-defined custom fields: the `FieldDefinition` registry
  and the `Changes.ApplyCustomFields` coercion/validation that gates the
  `custom_fields` map on content writes.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cf-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp editor do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cf-editor-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })
  end

  defp define!(attrs, actor) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, name: "f#{System.unique_integer([:positive])}"}, attrs),
      actor: actor
    )
  end

  defp slug, do: "cf-#{System.unique_integer([:positive])}"

  describe "FieldDefinition registry" do
    test "admins define fields; the unique [content_type, name] holds" do
      admin = admin()

      define!(
        %{
          name: "toxicity_level",
          label: "Toxicity",
          field_type: :select,
          options: ~w(none low high)
        },
        admin
      )

      assert {:error, _} =
               CMS.create_field_definition(
                 %{content_type: :page, name: "toxicity_level", label: "Dup"},
                 actor: admin
               )
    end

    test "rejects an unknown content type" do
      assert {:error, _} =
               CMS.create_field_definition(
                 %{content_type: :nonsense, name: "x", label: "X"},
                 actor: admin()
               )
    end

    test "rejects an invalid machine name" do
      assert {:error, _} =
               CMS.create_field_definition(
                 %{content_type: :page, name: "Not Valid", label: "X"},
                 actor: admin()
               )
    end

    test "a select field requires options" do
      assert {:error, _} =
               CMS.create_field_definition(
                 %{
                   content_type: :page,
                   name: "sel",
                   label: "Sel",
                   field_type: :select,
                   options: []
                 },
                 actor: admin()
               )
    end

    test "editors may read but not define fields" do
      define!(%{name: "readable", label: "R"}, admin())
      ed = editor()

      assert is_list(CMS.field_definitions_for!(:page, actor: ed))

      assert {:error, _} =
               CMS.create_field_definition(%{content_type: :page, name: "nope", label: "N"},
                 actor: ed
               )
    end
  end

  describe "custom_fields coercion on content writes" do
    test "coerces declared types to JSON-native values" do
      admin = admin()
      define!(%{name: "storage_temp", label: "Storage temp", field_type: :integer}, admin)
      define!(%{name: "organic", label: "Organic", field_type: :boolean}, admin)
      define!(%{name: "harvested_on", label: "Harvested", field_type: :date}, admin)

      page =
        CMS.create_page!(
          %{
            title: "Herb",
            slug: slug(),
            custom_fields: %{
              "storage_temp" => "4",
              "organic" => "true",
              "harvested_on" => "2026-05-01"
            }
          },
          actor: admin
        )

      assert page.custom_fields == %{
               "storage_temp" => 4,
               "organic" => true,
               "harvested_on" => "2026-05-01"
             }
    end

    test "drops keys with no matching definition" do
      admin = admin()
      define!(%{name: "kept", label: "Kept", field_type: :string}, admin)

      page =
        CMS.create_page!(
          %{title: "H", slug: slug(), custom_fields: %{"kept" => "yes", "stray" => "no"}},
          actor: admin
        )

      assert page.custom_fields == %{"kept" => "yes"}
    end

    test "enforces required fields" do
      admin = admin()
      define!(%{name: "must", label: "Must", field_type: :string, required: true}, admin)

      assert {:error, _} =
               CMS.create_page(%{title: "H", slug: slug(), custom_fields: %{}}, actor: admin)
    end

    test "rejects a select value outside its options" do
      admin = admin()
      define!(%{name: "grade", label: "Grade", field_type: :select, options: ~w(a b c)}, admin)

      assert {:error, _} =
               CMS.create_page(
                 %{title: "H", slug: slug(), custom_fields: %{"grade" => "z"}},
                 actor: admin
               )
    end

    test "rejects an uncoercible number" do
      admin = admin()
      define!(%{name: "count", label: "Count", field_type: :integer}, admin)

      assert {:error, _} =
               CMS.create_page(
                 %{title: "H", slug: slug(), custom_fields: %{"count" => "not-a-number"}},
                 actor: admin
               )
    end

    test "applies a field default when the value is blank" do
      admin = admin()
      define!(%{name: "region", label: "Region", field_type: :string, default: "unknown"}, admin)

      page = CMS.create_page!(%{title: "H", slug: slug(), custom_fields: %{}}, actor: admin)

      assert page.custom_fields == %{"region" => "unknown"}
    end
  end

  describe "custom_fields partial updates merge over the stored map" do
    setup do
      admin = admin()
      define!(%{name: "genus", label: "Genus", field_type: :string}, admin)
      define!(%{name: "species", label: "Species", field_type: :string}, admin)
      define!(%{name: "notes", label: "Notes", field_type: :text}, admin)

      page =
        CMS.create_page!(
          %{
            title: "Plant",
            slug: slug(),
            custom_fields: %{"genus" => "Panax", "species" => "ginseng", "notes" => "keep me"}
          },
          actor: admin
        )

      %{admin: admin, page: page}
    end

    test "a field omitted from the payload keeps its stored value", %{admin: admin, page: page} do
      updated =
        CMS.update_page!(page, %{custom_fields: %{"species" => "quinquefolius"}}, actor: admin)

      # The one supplied field changes; the two omitted fields are untouched —
      # not wiped by the full-map rewrite.
      assert updated.custom_fields == %{
               "genus" => "Panax",
               "species" => "quinquefolius",
               "notes" => "keep me"
             }
    end

    test "a field supplied blank is cleared, siblings preserved", %{admin: admin, page: page} do
      updated = CMS.update_page!(page, %{custom_fields: %{"notes" => ""}}, actor: admin)

      refute Map.has_key?(updated.custom_fields, "notes")
      assert updated.custom_fields == %{"genus" => "Panax", "species" => "ginseng"}
    end

    test "an empty custom_fields payload changes nothing", %{admin: admin, page: page} do
      updated = CMS.update_page!(page, %{custom_fields: %{}}, actor: admin)

      assert updated.custom_fields == page.custom_fields
    end

    test "a required field omitted from a partial update keeps its stored value", %{admin: admin} do
      define!(%{name: "req", label: "Req", field_type: :string, required: true}, admin)

      page =
        CMS.create_page!(
          %{title: "R", slug: slug(), custom_fields: %{"req" => "present", "genus" => "A"}},
          actor: admin
        )

      # Not resending `req` doesn't trip the required validation — the stored
      # value stands.
      updated = CMS.update_page!(page, %{custom_fields: %{"genus" => "B"}}, actor: admin)

      assert updated.custom_fields["req"] == "present"
      assert updated.custom_fields["genus"] == "B"
    end

    test "unknown keys in a partial update are still dropped", %{admin: admin, page: page} do
      updated =
        CMS.update_page!(page, %{custom_fields: %{"genus" => "New", "stray" => "x"}},
          actor: admin
        )

      refute Map.has_key?(updated.custom_fields, "stray")
      assert updated.custom_fields["genus"] == "New"
      assert updated.custom_fields["notes"] == "keep me"
    end

    # The form editor renders an input for *every* definition and submits the
    # complete map (blank for empties), so a full-map update that empties a field
    # must still clear it — merge semantics must not resurrect emptied fields.
    test "a full-map update (editor shape) still clears an emptied field", %{
      admin: admin,
      page: page
    } do
      updated =
        CMS.update_page!(
          page,
          %{custom_fields: %{"genus" => "Panax", "species" => "ginseng", "notes" => ""}},
          actor: admin
        )

      refute Map.has_key?(updated.custom_fields, "notes")
      assert updated.custom_fields == %{"genus" => "Panax", "species" => "ginseng"}
    end
  end
end
