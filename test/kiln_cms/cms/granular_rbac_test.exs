defmodule KilnCMS.CMS.GranularRbacTest do
  @moduledoc "Per-content-type authoring scope for editors (granular RBAC, #332)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "rbac-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp slug, do: "rbac-#{System.unique_integer([:positive])}"

  test "an unscoped editor (empty editable_types) can author any type" do
    editor = user(:editor)

    assert {:ok, _} = CMS.create_post(%{title: "P", slug: slug()}, actor: editor)
    assert {:ok, _} = CMS.create_page(%{title: "Pg", slug: slug()}, actor: editor)
  end

  test "a scoped editor can create only the listed types" do
    editor = user(:editor, %{editable_types: ["post"]})

    assert {:ok, _} = CMS.create_post(%{title: "P", slug: slug()}, actor: editor)

    assert {:error, %Ash.Error.Forbidden{}} =
             CMS.create_page(%{title: "Pg", slug: slug()}, actor: editor)
  end

  test "a scoped editor cannot update an out-of-scope type" do
    admin = user(:admin)
    page = CMS.create_page!(%{title: "Pg", slug: slug()}, actor: admin)

    editor = user(:editor, %{editable_types: ["post"]})

    assert {:error, %Ash.Error.Forbidden{}} =
             CMS.update_page(page, %{title: "Renamed"}, actor: editor)

    # …but can update a type that IS in scope.
    post = CMS.create_post!(%{title: "P", slug: slug()}, actor: editor)
    assert {:ok, _} = CMS.update_post(post, %{title: "Renamed"}, actor: editor)
  end

  test "admins author any type regardless of scope" do
    # An admin with a (meaningless) scope still authors everything via the bypass.
    admin = user(:admin, %{editable_types: ["post"]})
    assert {:ok, _} = CMS.create_page(%{title: "Pg", slug: slug()}, actor: admin)
  end

  test "an admin grants scope via :manage_access" do
    admin = user(:admin)
    editor = user(:editor)

    {:ok, editor} =
      KilnCMS.Accounts.manage_user_access(editor, %{editable_types: ["post"]}, actor: admin)

    assert editor.editable_types == ["post"]

    assert {:error, %Ash.Error.Forbidden{}} =
             CMS.create_page(%{title: "Pg", slug: slug()}, actor: editor)
  end

  # editable_types groups every dynamic (D17) type under the shared "entry"
  # storage key, per docs/granular-rbac.md — unlike field_grants, which is
  # per-type (#927). Previously `["entry"]` matched no dynamic type at all,
  # because the check resolved the group key via the module-only `type_name/1`
  # (`nil` for `KilnCMS.CMS.Entry`, which deliberately doesn't export
  # `__kiln_content_type__/0`) instead of `scope_group_name/1` (#1175).
  describe "dynamic content types (#1175)" do
    setup do
      admin = user(:admin)
      name = "recipe#{System.unique_integer([:positive])}"
      definition = CMS.create_type_definition!(%{name: name, label: "Recipe"}, actor: admin)
      %{admin: admin, definition: definition}
    end

    test "an editor scoped to \"entry\" can author any dynamic type", %{
      admin: admin,
      definition: d
    } do
      editor = user(:editor, %{editable_types: ["entry"]})

      assert %KilnCMS.CMS.Entry{} =
               KilnCMS.CMS.ContentTypes.create!(
                 d.name,
                 %{title: "A recipe", slug: slug(), blocks: []},
                 actor: editor
               )

      entry =
        KilnCMS.CMS.ContentTypes.create!(
          d.name,
          %{title: "Another", slug: slug(), blocks: []},
          actor: admin
        )

      assert {:ok, _} =
               KilnCMS.CMS.ContentTypes.update(d.name, entry, %{title: "Renamed"}, actor: editor)
    end

    test "an editor scoped to a compiled type cannot author a dynamic type", %{definition: d} do
      editor = user(:editor, %{editable_types: ["post"]})

      assert_raise Ash.Error.Forbidden, fn ->
        KilnCMS.CMS.ContentTypes.create!(
          d.name,
          %{title: "A recipe", slug: slug(), blocks: []},
          actor: editor
        )
      end
    end
  end
end
