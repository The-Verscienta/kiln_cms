defmodule KilnCMS.CMS.SectionLayoutsTest do
  @moduledoc """
  A section's layout (`KilnCMS.CMS.FieldSection`) lives only while a
  top-level field carries the section's name (#2652): every field definition
  update and destroy that takes a field out of a section prunes the layout it
  left behind, in the field write's own transaction
  (`KilnCMS.CMS.Changes.KeepSectionLayouts`), and a rename that asks for it
  carries the layout to the new name (`KilnCMS.CMS.SectionLayouts.carry/4`).
  A layout that cannot be kept in step fails the field write.
  """
  # Async, so its names are its own: rows sharing a unique key with another
  # file's, inserted in another order, deadlock in Postgres.
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Errors.SectionLayoutNotKept
  alias KilnCMS.CMS.SectionLayouts
  alias KilnCMS.NewerReleaseRows

  import KilnCMS.SectionLayoutFixtures, only: [orphan_layout!: 1]

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "slay-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  setup do
    {:ok, admin: user(:admin)}
  end

  defp field!(admin, name, section, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{content_type: :page, name: name, label: name, field_type: :string, section: section},
        attrs
      ),
      actor: admin
    )
  end

  defp layout!(admin, name, attrs \\ %{}) do
    CMS.create_field_section!(
      Map.merge(%{content_type: :page, name: name, display: :tab}, attrs),
      actor: admin
    )
  end

  defp layouts(type \\ :page),
    do: type |> CMS.field_sections_for!(authorize?: false) |> Map.new(&{&1.name, &1})

  defp rename!(admin, field, section, carry? \\ true) do
    CMS.update_field_definition!(
      field,
      %{section: section, carry_section_layout?: carry?},
      actor: admin
    )
  end

  describe "a field leaving its section" do
    test "a rename prunes the layout its last field left behind", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      layout!(admin, "Slay Identity")

      rename!(admin, latin, "Slay Names", false)

      assert layouts() == %{}
    end

    test "a rename keeps the layout while another field carries it", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      field!(admin, "slay_pinyin", "Slay Identity")
      layout!(admin, "Slay Identity")

      rename!(admin, latin, "Slay Names")

      assert %{"Slay Identity" => %{display: :tab}} = layouts()
      refute Map.has_key?(layouts(), "Slay Names")
    end

    test "an owner move prunes the layout on the type it left", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      layout!(admin, "Slay Identity")

      CMS.update_field_definition!(latin, %{content_type: :post}, actor: admin)

      assert layouts() == %{}
      # The section on its new type has no layout of its own.
      assert layouts(:post) == %{}
    end

    test "a destroy through the code interface drops its section's layout", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      dose = field!(admin, "slay_dose", "Slay Dosing")
      field!(admin, "slay_amount", "Slay Dosing")
      layout!(admin, "Slay Identity")
      layout!(admin, "Slay Dosing")

      :ok = CMS.destroy_field_definition!(dose, actor: admin)
      assert %{"Slay Identity" => _, "Slay Dosing" => _} = layouts()

      :ok = CMS.destroy_field_definition!(latin, actor: admin)
      assert Map.keys(layouts()) == ["Slay Dosing"]
    end

    test "a field of a type this release does not know still carries its section",
         %{admin: admin} do
      NewerReleaseRows.field_definition!(%{name: "slay_specs", section: "Slay Specs"})
      latin = field!(admin, "slay_latin", "Slay Specs")
      layout!(admin, "Slay Specs")

      rename!(admin, latin, "Slay Names", false)

      assert %{"Slay Specs" => %{display: :tab}} = layouts()
    end

    test "a move from a dynamic type to a compiled one prunes the layout it left (#2881)",
         %{admin: admin} do
      type =
        CMS.create_type_definition!(
          %{name: "slay_move_#{System.unique_integer([:positive])}", label: "Slay"},
          actor: admin
        )

      latin =
        field!(admin, "slay_latin", "Slay Identity", %{
          content_type: nil,
          type_definition_id: type.id
        })

      CMS.create_field_section!(
        %{type_definition_id: type.id, name: "Slay Identity", display: :tab},
        actor: admin
      )

      CMS.update_field_definition!(
        latin,
        %{content_type: :page, type_definition_id: nil},
        actor: admin
      )

      assert CMS.field_sections_for_definition!(type.id, authorize?: false) == []
      assert layouts() == %{}
    end

    test "a write that leaves the section alone reads nothing and keeps it", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      layout!(admin, "Slay Identity")

      CMS.update_field_definition!(latin, %{label: "Latin name"}, actor: admin)

      assert %{"Slay Identity" => %{display: :tab}} = layouts()
    end
  end

  describe "a write built from a stale struct" do
    # Another admin moved the field after this write's struct was read: the
    # write decides from where the field is now, read in its transaction.
    test "a rename carries and prunes the section the field is in now", %{admin: admin} do
      stale = field!(admin, "slay_latin", "Slay Identity")
      layout!(admin, "Slay Identity")

      CMS.update_field_definition!(stale, %{section: "Slay Moved"}, actor: user(:admin))
      layout!(admin, "Slay Moved", %{display: :fieldset})

      rename!(admin, stale, "Slay Names")

      assert CMS.get_field_definition!(stale.id, actor: admin).section == "Slay Names"
      assert %{"Slay Names" => %{display: :fieldset}} = layouts()
      assert Map.keys(layouts()) == ["Slay Names"]
    end

    test "a destroy prunes the section the field is in now", %{admin: admin} do
      stale = field!(admin, "slay_latin", "Slay Identity")
      field!(admin, "slay_pinyin", "Slay Identity")
      layout!(admin, "Slay Identity")

      CMS.update_field_definition!(stale, %{section: "Slay Moved"}, actor: user(:admin))
      layout!(admin, "Slay Moved", %{display: :fieldset})

      :ok = CMS.destroy_field_definition!(stale, actor: admin)

      assert Map.keys(layouts()) == ["Slay Identity"]
    end

    test "a field another write deleted is not a layout failure (#3062)", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      layout!(admin, "Slay Identity")
      assert :ok = CMS.destroy_field_definition(latin, actor: admin)

      assert {:error, error} = CMS.destroy_field_definition(latin, actor: admin)
      refute not_kept?(error)

      assert Enum.any?(
               Ash.Error.to_error_class(error).errors,
               &match?(%Ash.Error.Query.NotFound{}, &1)
             )

      assert {:error, error} =
               CMS.update_field_definition(latin, %{section: "Slay Names"}, actor: admin)

      refute not_kept?(error)
    end

    test "a write that sets no section or owner reads nothing and moves nothing",
         %{admin: admin} do
      stale = field!(admin, "slay_latin", "Slay Identity")
      layout!(admin, "Slay Identity")

      CMS.update_field_definition!(stale, %{section: "Slay Moved"}, actor: user(:admin))
      layout!(admin, "Slay Moved", %{display: :fieldset})

      CMS.update_field_definition!(stale, %{label: "Latin name"}, actor: admin)

      assert CMS.get_field_definition!(stale.id, actor: admin).section == "Slay Moved"
      assert %{"Slay Moved" => %{display: :fieldset}} = layouts()
    end
  end

  describe "carrying a layout on a rename" do
    test "to a name with no row: the layout moves", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      layout!(admin, "Slay Identity", %{initially: :collapsed})

      rename!(admin, latin, "Slay Names")

      assert %{"Slay Names" => %{display: :tab, initially: :collapsed}} = layouts()
      refute Map.has_key?(layouts(), "Slay Identity")
    end

    test "to a name other fields carry already, with no row: the layout moves",
         %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      field!(admin, "slay_dose", "Slay Names")
      layout!(admin, "Slay Identity")

      rename!(admin, latin, "Slay Names")

      assert %{"Slay Names" => %{display: :tab}} = layouts()
      refute Map.has_key?(layouts(), "Slay Identity")
    end

    test "to a name with a stored default row: the row takes the layout", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      field!(admin, "slay_dose", "Slay Names")
      layout!(admin, "Slay Identity", %{display: :fieldset})
      legacy = layout!(admin, "Slay Names", %{display: :accordion, initially: :auto})

      rename!(admin, latin, "Slay Names")

      assert %{"Slay Names" => %{id: id, display: :fieldset}} = layouts()
      assert id == legacy.id
      refute Map.has_key?(layouts(), "Slay Identity")
    end

    test "to a name with a layout of its own: that layout stays", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      field!(admin, "slay_dose", "Slay Names")
      layout!(admin, "Slay Identity")
      layout!(admin, "Slay Names", %{display: :fieldset})

      rename!(admin, latin, "Slay Names")

      assert %{"Slay Names" => %{display: :fieldset}} = layouts()
      refute Map.has_key?(layouts(), "Slay Identity")
    end

    test "carry/4 moves nothing from a section with no row, or onto itself", %{admin: admin} do
      field!(admin, "slay_dose", "Slay Names")
      layout!(admin, "Slay Names", %{display: :fieldset})
      opts = [actor: admin]

      assert :ok = SectionLayouts.carry({:compiled, :page}, "Slay Gone", "Slay New", opts)
      assert :ok = SectionLayouts.carry({:compiled, :page}, "Slay Names", "Slay Names", opts)

      assert Map.keys(layouts()) == ["Slay Names"]
    end

    test "a cleared section prunes, and carries nowhere", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      layout!(admin, "Slay Identity")

      rename!(admin, latin, nil)

      assert layouts() == %{}
    end
  end

  describe "a layout that cannot be kept" do
    test "a refused read deletes nothing", %{admin: admin} do
      field!(admin, "slay_latin", "Slay Identity")
      orphan_layout!(%{name: "Slay Gone"})

      assert {:error, %Ash.Error.Forbidden{}} =
               SectionLayouts.prune({:compiled, :page}, actor: user(:viewer))

      assert Map.keys(layouts()) == ["Slay Gone"]
    end

    test "a failed field update leaves the layouts as they were", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      layout!(admin, "Slay Identity")

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.update_field_definition(
                 latin,
                 %{section: "Slay Names", name: "Not A Name", carry_section_layout?: true},
                 actor: admin
               )

      assert %{"Slay Identity" => %{display: :tab}} = layouts()
      refute Map.has_key?(layouts(), "Slay Names")
    end

    test "a carry refused fails the rename, tagged, and rolls it back", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      layout!(admin, "Slay Identity")
      legacy = broken_default_row!(admin, "Slay Names")

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               CMS.update_field_definition(
                 latin,
                 %{section: "Slay Names", carry_section_layout?: true},
                 actor: admin
               )

      assert Enum.any?(errors, &match?(%SectionLayoutNotKept{section: "Slay Identity"}, &1))
      assert CMS.get_field_definition!(latin.id, actor: admin).section == "Slay Identity"
      assert %{"Slay Identity" => %{display: :tab}, "Slay Names" => %{id: id}} = layouts()
      assert id == legacy.id
    end

    test "a prune that fails rolls back the update, and the destroy", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      layout = layout!(admin, "Slay Identity")
      unloadable!(layout)

      assert {:error, error} =
               CMS.update_field_definition(latin, %{section: "Slay Names"}, actor: admin)

      # Tagged, so the fields admin can name the cause (#3062).
      assert not_kept?(error)
      assert CMS.get_field_definition!(latin.id, actor: admin).section == "Slay Identity"

      assert {:error, error} = CMS.destroy_field_definition(latin, actor: admin)
      assert not_kept?(error)
      assert {:ok, _still_there} = CMS.get_field_definition(latin.id, actor: admin)
      assert stored_layout_count() == 1
    end
  end

  defp not_kept?(error),
    do: Enum.any?(Ash.Error.to_error_class(error).errors, &match?(%SectionLayoutNotKept{}, &1))

  describe "who may move a section's last field" do
    test "an editor's rename is refused, and the layouts are as they were", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      layout!(admin, "Slay Identity")
      editor = user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_field_definition(
                 latin,
                 %{section: "Slay Names", carry_section_layout?: true},
                 actor: editor
               )

      assert {:error, %Ash.Error.Forbidden{}} = CMS.destroy_field_definition(latin, actor: editor)

      assert CMS.get_field_definition!(latin.id, actor: admin).section == "Slay Identity"
      assert %{"Slay Identity" => %{display: :tab}} = layouts()
      refute Map.has_key?(layouts(), "Slay Names")
    end

    # The layout writes run as the field write's own actor: whoever may move
    # a field out of its section may also read, carry and prune its layout,
    # so an allowed field write never fails on the layout's policy, and a
    # refused one never reaches it.
    test "whoever may write a field may write and read its section's layout", %{admin: admin} do
      latin = field!(admin, "slay_latin", "Slay Identity")
      row = layout!(admin, "Slay Identity")

      for actor <- [admin, user(:editor), user(:viewer), nil] do
        field_write? =
          CMS.can_update_field_definition?(actor, latin, %{section: "Slay Names"}) or
            CMS.can_destroy_field_definition?(actor, latin)

        if field_write? do
          assert CMS.can_create_field_section?(actor, %{content_type: :page, name: "Slay N"})
          assert CMS.can_update_field_section?(actor, row, %{display: :fieldset})
          assert CMS.can_destroy_field_section?(actor, row)
          assert CMS.can_list_field_sections?(actor)
          assert CMS.can_list_field_definitions?(actor)
        end

        assert field_write? == (actor == admin)
      end
    end
  end

  # A row at the defaults stored by an older release, with an owner each way:
  # the carry's update of it is refused by `FieldSection`'s own validation.
  defp broken_default_row!(admin, name) do
    type =
      CMS.create_type_definition!(
        %{name: "slay_type_#{System.unique_integer([:positive])}", label: "Slay"},
        actor: admin
      )

    Ash.Seed.seed!(KilnCMS.CMS.FieldSection, %{
      content_type: :page,
      type_definition_id: type.id,
      name: name,
      display: :accordion,
      initially: :auto
    })
  end

  # A row no read can load: the layouts read under the prune fails.
  defp unloadable!(layout) do
    KilnCMS.Repo.query!(
      "UPDATE field_sections SET display = $1 WHERE id = $2",
      ["zz_display_from_a_newer_release_2652", Ecto.UUID.dump!(layout.id)]
    )
  end

  defp stored_layout_count do
    %{rows: [[count]]} =
      KilnCMS.Repo.query!("SELECT count(*) FROM field_sections WHERE name LIKE 'Slay %'")

    count
  end
end
