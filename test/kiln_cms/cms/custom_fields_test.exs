defmodule KilnCMS.CMS.CustomFieldsTest do
  @moduledoc """
  Coverage for admin-UI-defined custom fields: the `FieldDefinition` registry
  and the `Changes.ApplyCustomFields` coercion/validation that gates the
  `custom_fields` map on content writes.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog

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

    test "refuses a key with no matching definition, naming what is defined" do
      admin = admin()
      define!(%{name: "kept", label: "Kept", field_type: :string}, admin)

      # This used to store %{"kept" => "yes"} and report success, so prose
      # typed under a key nobody had defined left no trace anywhere.
      assert {:error, error} =
               CMS.create_page(
                 %{title: "H", slug: slug(), custom_fields: %{"kept" => "yes", "stray" => "no"}},
                 actor: admin
               )

      message = Exception.message(error)
      assert message =~ ~s("stray" is not a defined custom field)
      assert message =~ "defined fields: kept"
    end

    test "says so plainly when the type defines no custom fields at all" do
      assert {:error, error} =
               CMS.create_page(
                 %{title: "H", slug: slug(), custom_fields: %{"stray" => "no"}},
                 actor: admin()
               )

      assert Exception.message(error) =~ "this content type defines no custom fields"
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

    test "an unknown key in a partial update fails the write", %{admin: admin, page: page} do
      assert {:error, error} =
               CMS.update_page(page, %{custom_fields: %{"genus" => "New", "stray" => "x"}},
                 actor: admin
               )

      assert Exception.message(error) =~ ~s("stray" is not a defined custom field)

      # And the write it belonged to did not land, so the editor is looking at
      # the same document they tried to save rather than a half-saved one.
      assert Ash.reload!(page, actor: admin).custom_fields["genus"] == "Panax"
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

  describe "custom_fields keys with no definition" do
    setup do
      admin = admin()
      definition = define!(%{name: "prose", label: "Prose", field_type: :text}, admin)
      define!(%{name: "kept", label: "Kept", field_type: :string}, admin)

      page =
        CMS.create_page!(
          %{
            title: "Combination",
            slug: slug(),
            custom_fields: %{"prose" => "three paragraphs", "kept" => "yes"}
          },
          actor: admin
        )

      %{admin: admin, definition: definition, page: page}
    end

    test "retiring the definition purges its values there and then", %{
      admin: admin,
      definition: definition,
      page: page
    } do
      CMS.destroy_field_definition!(definition, actor: admin)

      # Not "on the next write of each record" — which is how an edit to a
      # title came to be what destroyed the prose.
      assert CMS.get_page!(page.id, actor: admin).custom_fields == %{"kept" => "yes"}
    end

    test "renaming the definition moves the values instead of stranding them", %{
      admin: admin,
      definition: definition,
      page: page
    } do
      CMS.update_field_definition!(definition, %{name: "body_prose"}, actor: admin)

      # A rename never asked for anything to be lost. Before this the field just
      # emptied itself in the editor and the prose was dropped, one record at a
      # time, by whatever wrote each record next.
      assert CMS.get_page!(page.id, actor: admin).custom_fields == %{
               "body_prose" => "three paragraphs",
               "kept" => "yes"
             }
    end

    test "an edit that leaves the name alone leaves the values alone", %{
      admin: admin,
      definition: definition,
      page: page
    } do
      CMS.update_field_definition!(definition, %{label: "Prose (long)"}, actor: admin)

      assert CMS.get_page!(page.id, actor: admin).custom_fields["prose"] == "three paragraphs"
    end

    test "the purge is scoped to the field, the type and nothing else", %{
      admin: admin,
      definition: definition
    } do
      define!(%{name: "prose", label: "Prose", field_type: :text, content_type: :post}, admin)

      post =
        CMS.create_post!(
          %{title: "P", slug: slug(), custom_fields: %{"prose" => "untouched"}},
          actor: admin
        )

      CMS.destroy_field_definition!(definition, actor: admin)

      assert CMS.get_post!(post.id, actor: admin).custom_fields == %{"prose" => "untouched"}
    end

    test "a stale key from before the purge existed is dropped, loudly", %{
      admin: admin,
      page: page
    } do
      orphan!(page)
      page = CMS.get_page!(page.id, actor: admin)

      # The write mentions one *other* field. The map is rewritten out of the
      # definitions either way, so the key it never mentioned goes with it —
      # trap 3, now at least announced.
      log =
        capture_log(fn ->
          updated = CMS.update_page!(page, %{custom_fields: %{"kept" => "changed"}}, actor: admin)

          refute Map.has_key?(updated.custom_fields, "stale")
          assert updated.custom_fields == %{"kept" => "changed", "prose" => "three paragraphs"}
        end)

      assert log =~ ~s|dropped "stale"|
    end

    test "re-sending a stale key's own value is not treated as introducing it", %{
      admin: admin,
      page: page
    } do
      orphan!(page)
      page = CMS.get_page!(page.id, actor: admin)

      # A client that reads the record, edits one field and writes the whole map
      # back is not asking for anything — refusing it would lock such a record
      # out of every update until somebody hand-edited the payload.
      updated =
        capture_log(fn ->
          CMS.update_page!(
            page,
            %{custom_fields: %{"stale" => "left over", "kept" => "changed"}},
            actor: admin
          )
        end)
        |> then(fn _log -> CMS.get_page!(page.id, actor: admin) end)

      assert updated.custom_fields["kept"] == "changed"
      refute Map.has_key?(updated.custom_fields, "stale")
    end

    test "a NEW value under a stale key is still refused", %{admin: admin, page: page} do
      orphan!(page)
      page = CMS.get_page!(page.id, actor: admin)

      assert {:error, error} =
               CMS.update_page(page, %{custom_fields: %{"stale" => "rewritten"}}, actor: admin)

      assert Exception.message(error) =~ ~s("stale" is not a defined custom field)
    end

    test "a duplicate drops it rather than failing the copy", %{admin: admin, page: page} do
      orphan!(page)
      page = CMS.get_page!(page.id, actor: admin)

      copy =
        capture_log(fn ->
          KilnCMS.CMS.Duplication.duplicate!(:page, page, actor: admin)
        end)
        |> then(fn log ->
          assert log =~ ~s|dropped "stale"|
          CMS.get_page!(page.id, actor: admin)
        end)

      # The source is untouched by the copy; the copy simply didn't carry it.
      assert copy.custom_fields["kept"] == "yes"
    end

    # A key that no definition declares, written straight into the row — the
    # state a record could be left in by a release that predates the purge, and
    # the only way to reach it now that the write path refuses one.
    defp orphan!(page) do
      KilnCMS.Repo.query!(
        "UPDATE pages SET custom_fields = jsonb_set(custom_fields, '{stale}', to_jsonb($2::text)) WHERE id = $1",
        [Ecto.UUID.dump!(page.id), "left over"]
      )
    end
  end
end
