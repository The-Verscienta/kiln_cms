defmodule KilnCMS.CMS.FieldSectionTest do
  @moduledoc """
  The per-type layout of custom-field sections (#2280, `KilnCMS.CMS.FieldSection`):
  who may read and write it, that it stays inside its site, its owner and
  name rules, and the per-field `width` beside it, which only a record-level
  field keeps.
  """
  # Async, so its names are its own: rows sharing a unique key with another
  # file's, inserted in another order, deadlock in Postgres.
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fsec-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  setup do
    {:ok, admin: user(:admin)}
  end

  defp section!(admin, attrs, opts \\ []) do
    CMS.create_field_section!(
      Map.merge(%{content_type: :post, name: "Fsec layout"}, attrs),
      [actor: admin] ++ opts
    )
  end

  describe "defaults and owners" do
    test "a new layout is an accordion that opens by the panel's heuristic", %{admin: admin} do
      section = section!(admin, %{})
      assert section.display == :accordion
      assert section.initially == :auto
    end

    test "an admin changes the layout, and removes it", %{admin: admin} do
      section = section!(admin, %{})

      updated =
        CMS.update_field_section!(section, %{display: :tab, initially: :collapsed}, actor: admin)

      assert updated.display == :tab and updated.initially == :collapsed
      assert [%{display: :tab}] = CMS.field_sections_for!(:post, actor: admin)

      assert :ok = CMS.destroy_field_section!(updated, actor: admin)
      assert CMS.field_sections_for!(:post, actor: admin) == []
    end

    test "a dynamic type's layouts are read by its id", %{admin: admin} do
      type = CMS.create_type_definition!(%{name: "fsec_recipe", label: "Recipe"}, actor: admin)

      section!(admin, %{content_type: nil, type_definition_id: type.id, display: :fieldset})

      assert [%{name: "Fsec layout", display: :fieldset}] =
               CMS.field_sections_for_definition!(type.id, actor: admin)

      assert CMS.field_sections_for!(:post, actor: admin) == []
    end

    test "belongs to exactly one owner, a known type", %{admin: admin} do
      type = CMS.create_type_definition!(%{name: "fsec_item", label: "Item"}, actor: admin)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_field_section(%{name: "Fsec orphan"}, actor: admin)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_field_section(
                 %{content_type: :post, type_definition_id: type.id, name: "Fsec both"},
                 actor: admin
               )

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_field_section(%{content_type: :nope_type, name: "X"}, actor: admin)
    end

    test "one layout per section name per type", %{admin: admin} do
      section!(admin, %{})

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_field_section(%{content_type: :post, name: "Fsec layout"}, actor: admin)

      assert %{name: "Fsec layout"} = section!(admin, %{content_type: :page})
    end

    test "refuses a display or initial state it does not know", %{admin: admin} do
      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_field_section(
                 %{content_type: :post, name: "X", display: :carousel},
                 actor: admin
               )

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_field_section(
                 %{content_type: :post, name: "X", initially: :maybe},
                 actor: admin
               )
    end
  end

  describe "policies" do
    test "an editor reads a type's layout but cannot write one", %{admin: admin} do
      section = section!(admin, %{})
      editor = user(:editor)

      assert [%{name: "Fsec layout"}] = CMS.field_sections_for!(:post, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_field_section(%{content_type: :post, name: "Fsec other"}, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_field_section(section, %{display: :tab}, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} = CMS.destroy_field_section(section, actor: editor)
    end

    test "a viewer neither reads nor writes one", %{admin: admin} do
      section = section!(admin, %{})
      viewer = user(:viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.field_sections_for(:post, actor: viewer, authorize_with: :error)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_field_section(%{content_type: :post, name: "Fsec other"}, actor: viewer)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_field_section(section, %{display: :tab}, actor: viewer)
    end

    test "anonymous callers are refused", %{admin: admin} do
      section!(admin, %{})

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.field_sections_for(:post, actor: nil, authorize_with: :error)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_field_section(%{content_type: :post, name: "Fsec other"}, actor: nil)
    end

    test "the schema export's system actor reads; another subsystem does not",
         %{admin: admin} do
      section!(admin, %{})

      assert [%{name: "Fsec layout"}] =
               CMS.field_sections_for!(:post,
                 actor: KilnCMS.SystemActor.new(:schema_export),
                 authorize_with: :error
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.field_sections_for(:post,
                 actor: KilnCMS.SystemActor.new(:firing),
                 authorize_with: :error
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_field_section(%{content_type: :post, name: "Fsec other"},
                 actor: KilnCMS.SystemActor.new(:schema_export)
               )
    end
  end

  describe "tenancy" do
    test "a site reads only its own layouts", %{admin: admin} do
      a = org("fsec-a")
      b = org("fsec-b")

      section!(admin, %{display: :tab}, tenant: a)
      section!(admin, %{display: :fieldset}, tenant: b)

      assert [%{display: :tab, org_id: a_id}] =
               CMS.field_sections_for!(:post, actor: admin, tenant: a)

      assert a_id == a.id
      assert [%{display: :fieldset}] = CMS.field_sections_for!(:post, actor: admin, tenant: b)
    end

    test "another site's editor sees none of them", %{admin: admin} do
      other = org("fsec-other")
      section!(admin, %{}, tenant: other)

      # A membership-less editor is an editor of the default org only.
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.field_sections_for(:post,
                 actor: user(:editor),
                 tenant: other,
                 authorize_with: :error
               )

      # And under their own site, the other site's row is not there.
      assert CMS.field_sections_for!(:post,
               actor: user(:editor),
               tenant: KilnCMS.Accounts.default_org_id()
             ) == []
    end
  end

  describe "field width" do
    test "a record-level field keeps its width; full is the default", %{admin: admin} do
      plain =
        CMS.create_field_definition!(
          %{content_type: :post, name: "fsec_plain", label: "Plain"},
          actor: admin
        )

      half =
        CMS.create_field_definition!(
          %{content_type: :post, name: "fsec_half", label: "Half", width: :half},
          actor: admin
        )

      assert plain.width == :full
      assert half.width == :half
      assert CMS.update_field_definition!(half, %{width: :third}, actor: admin).width == :third
    end

    test "a link field and a group sub-field are always full width", %{admin: admin} do
      ref =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: "fsec_related",
            label: "Related",
            field_type: :reference,
            target_type: "page"
          },
          actor: admin
        )

      link =
        CMS.create_field_definition!(
          %{
            link_of_id: ref.id,
            name: "fsec_qty",
            label: "Qty",
            field_type: :integer,
            width: :half
          },
          actor: admin
        )

      group =
        CMS.create_field_definition!(
          %{content_type: :post, name: "fsec_doses", label: "Doses", field_type: :group},
          actor: admin
        )

      sub =
        CMS.create_field_definition!(
          %{group_of_id: group.id, name: "fsec_unit", label: "Unit", width: :third},
          actor: admin
        )

      assert link.width == :full
      assert sub.width == :full
      assert CMS.update_field_definition!(sub, %{width: :half}, actor: admin).width == :full
    end

    test "refuses a width it does not know", %{admin: admin} do
      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_field_definition(
                 %{content_type: :post, name: "fsec_wide", label: "Wide", width: :double},
                 actor: admin
               )
    end
  end
end
