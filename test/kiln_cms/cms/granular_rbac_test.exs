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
end
