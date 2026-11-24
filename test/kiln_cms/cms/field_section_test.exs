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

  # A layout, and a field of its owner filed under its section first: the
  # create refuses a section no field is in (#3061).
  defp section!(admin, attrs, opts \\ []) do
    attrs = Map.merge(%{content_type: :post, name: "Fsec layout"}, attrs)
    carrier!(admin, attrs, opts)
    CMS.create_field_section!(attrs, [actor: admin] ++ opts)
  end

  defp carrier!(admin, attrs, opts, extra \\ %{}) do
    CMS.create_field_definition!(
      attrs
      |> Map.take([:content_type, :type_definition_id])
      |> Map.merge(%{
        name: "fsec_carrier_#{System.unique_integer([:positive])}",
        label: "Carrier",
        section: attrs.name
      })
      |> Map.merge(extra),
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

  describe "a section no field carries (#3061)" do
    defp refused_on_name?(result) do
      match?(
        {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.InvalidAttribute{field: :name}]}},
        result
      )
    end

    defp stored(owner_attrs, name, opts) do
      opts = Keyword.put_new(opts, :authorize?, false)

      case owner_attrs do
        %{type_definition_id: id} -> CMS.field_sections_for_definition!(id, opts)
        %{content_type: type} -> CMS.field_sections_for!(type, opts)
      end
      |> Enum.filter(&(&1.name == name))
    end

    test "a compiled type's create is refused, and nothing is stored", %{admin: admin} do
      result =
        CMS.create_field_section(%{content_type: :post, name: "Fsec nobody"}, actor: admin)

      assert refused_on_name?(result)
      {:error, %{errors: [error]}} = result
      assert error.message =~ "not a section any top-level field"
      assert stored(%{content_type: :post}, "Fsec nobody", []) == []
    end

    test "a dynamic type's create is refused; once a field is in it, it is allowed",
         %{admin: admin} do
      type = CMS.create_type_definition!(%{name: "fsec_dyn", label: "Dyn"}, actor: admin)
      attrs = %{type_definition_id: type.id, name: "Fsec dyn", display: :tab}

      assert refused_on_name?(CMS.create_field_section(attrs, actor: admin))
      assert stored(attrs, "Fsec dyn", []) == []

      carrier!(admin, attrs, [])
      assert {:ok, %{display: :tab}} = CMS.create_field_section(attrs, actor: admin)
    end

    test "a field of another type in that section does not carry it", %{admin: admin} do
      carrier!(admin, %{content_type: :page, name: "Fsec elsewhere"}, [])

      assert refused_on_name?(
               CMS.create_field_section(%{content_type: :post, name: "Fsec elsewhere"},
                 actor: admin
               )
             )
    end

    test "a group sub-field or a link field in that section does not carry it",
         %{admin: admin} do
      group =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: "fsec_g_#{System.unique_integer([:positive])}",
            label: "Group",
            field_type: :group
          },
          actor: admin
        )

      ref =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: "fsec_r_#{System.unique_integer([:positive])}",
            label: "Related",
            field_type: :reference,
            target_type: "page"
          },
          actor: admin
        )

      sub =
        CMS.create_field_definition!(
          %{group_of_id: group.id, name: "fsec_sub", label: "Sub"},
          actor: admin
        )

      link =
        CMS.create_field_definition!(
          %{link_of_id: ref.id, name: "fsec_link", label: "Link", field_type: :integer},
          actor: admin
        )

      # Neither child keeps a section through the resource, so it is stored
      # the way a hand-edited row would be.
      KilnCMS.Repo.query!("UPDATE field_definitions SET section = $1 WHERE id = ANY($2)", [
        "Fsec nested",
        Enum.map([sub.id, link.id], &Ecto.UUID.dump!/1)
      ])

      assert refused_on_name?(
               CMS.create_field_section(%{content_type: :post, name: "Fsec nested"},
                 actor: admin
               )
             )
    end

    test "a field of a type this release does not register still carries it",
         %{admin: admin} do
      KilnCMS.NewerReleaseRows.field_definition!(%{content_type: "post", section: "Fsec newer"})

      assert {:ok, %{name: "Fsec newer"}} =
               CMS.create_field_section(%{content_type: :post, name: "Fsec newer"},
                 actor: admin
               )
    end

    test "a field in another site does not carry it, with or without a tenant",
         %{admin: admin} do
      other = org("fsec-carrier")
      carrier!(admin, %{content_type: :post, name: "Fsec theirs"}, tenant: other)

      default = KilnCMS.Accounts.default_org_id()
      attrs = %{content_type: :post, name: "Fsec theirs"}

      assert refused_on_name?(CMS.create_field_section(attrs, actor: admin, tenant: default))

      # Tenant-less (a fail-open build's global write): the row lands in the
      # default org, and the check reads that org, not every site.
      assert refused_on_name?(CMS.create_field_section(attrs, actor: admin))
      assert stored(attrs, "Fsec theirs", tenant: default) == []

      assert {:ok, %{org_id: org_id}} =
               CMS.create_field_section(attrs, actor: admin, tenant: other)

      assert org_id == other.id
    end

    test "a caller the policy refuses gets Forbidden, not the name error", %{admin: _admin} do
      for actor <- [user(:editor), user(:viewer), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.create_field_section(%{content_type: :post, name: "Fsec nobody"},
                   actor: actor
                 )
      end
    end

    test "an update changes the layout of a row an older release left", %{admin: admin} do
      section = KilnCMS.SectionLayoutFixtures.orphan_layout!(%{name: "Fsec left"})

      assert {:ok, %{display: :fieldset}} =
               CMS.update_field_section(section, %{display: :fieldset}, actor: admin)
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
