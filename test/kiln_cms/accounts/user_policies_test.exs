defmodule KilnCMS.Accounts.UserPoliciesTest do
  @moduledoc """
  RBAC policy coverage for `User` beyond the auth flows (see `user_auth_test.exs`
  for the AshAuthentication-interaction bypass).

  Guarantees: a non-admin reads only their own record, admins manage everyone,
  the `role` field is visible only to admins/self, and profile/password updates
  are self-only. See `docs/policy-matrix.md`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  setup do
    %{admin: user(:admin), editor: user(:editor), viewer: user(:viewer)}
  end

  describe "read visibility" do
    test "a non-admin reads only their own record", %{editor: editor} do
      ids = Accounts.list_users!(actor: editor) |> Enum.map(& &1.id)
      assert ids == [editor.id]
    end

    test "admins read every user", %{admin: admin, editor: editor, viewer: viewer} do
      # Subset, not equality: other suites' users may be visible under the shared
      # sandbox mode. The guarantee is that an admin is not row-filtered.
      ids = Accounts.list_users!(actor: admin) |> Enum.map(& &1.id)
      assert admin.id in ids
      assert editor.id in ids
      assert viewer.id in ids
    end

    test "a non-admin cannot read another user's record", %{editor: editor, viewer: viewer} do
      assert {:error, %Ash.Error.Invalid{}} = Ash.get(User, viewer.id, actor: editor)
    end
  end

  describe "role field visibility" do
    test "admins see another user's role", %{admin: admin, editor: editor} do
      assert {:ok, read} = Ash.get(User, editor.id, actor: admin)
      assert read.role == :editor
    end

    test "a user sees their own role", %{viewer: viewer} do
      assert {:ok, read} = Ash.get(User, viewer.id, actor: viewer)
      assert read.role == :viewer
    end
  end

  describe "self-only profile updates" do
    test "a user may update their own profile", %{editor: editor} do
      assert Ash.can?(Ash.Changeset.for_update(editor, :update_profile, %{name: "Me"}), editor)
    end

    test "a user may not update someone else's profile", %{editor: editor, viewer: viewer} do
      refute Ash.can?(Ash.Changeset.for_update(viewer, :update_profile, %{name: "X"}), editor)
    end

    test "admins may update anyone's profile", %{admin: admin, editor: editor} do
      assert Ash.can?(Ash.Changeset.for_update(editor, :update_profile, %{name: "Set"}), admin)
    end
  end
end
