defmodule KilnCMS.Accounts.RoleTest do
  @moduledoc "Custom roles + read-through-role scope resolution (#332, slice 4)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "role-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp slug, do: "role-#{System.unique_integer([:positive])}"

  defp seed_role(attrs) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.Role,
      Map.merge(
        %{
          name: "Role #{System.unique_integer([:positive])}",
          org_id: Accounts.default_org_id()
        },
        attrs
      )
    )
  end

  defp membership(user, attrs) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.OrgMembership,
      Map.merge(
        %{
          user_id: user.id,
          organization_id: Accounts.default_org_id(),
          role: :editor
        },
        attrs
      )
    )
  end

  describe "role management" do
    test "admins manage roles; editors cannot" do
      admin = user(:admin)
      editor = user(:editor)

      {:ok, role} =
        Accounts.create_role(
          %{name: "Blog editor", editable_types: ["post"], org_id: Accounts.default_org_id()},
          actor: admin
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.create_role(%{name: "Nope", org_id: Accounts.default_org_id()},
                 actor: editor
               )

      assert {:ok, _} = Accounts.update_role(role, %{description: "Posts only"}, actor: admin)
      assert :ok = Accounts.destroy_role(role, actor: admin)
    end

    test "role names are unique per org" do
      admin = user(:admin)
      org_id = Accounts.default_org_id()

      {:ok, _} = Accounts.create_role(%{name: "Twin", org_id: org_id}, actor: admin)
      assert {:error, _} = Accounts.create_role(%{name: "Twin", org_id: org_id}, actor: admin)
    end
  end

  describe "scope resolution through the role" do
    test "a membership's role bundle applies to authoring" do
      blog_editor = seed_role(%{editable_types: ["post"]})
      editor = user(:editor)
      membership(editor, %{role_id: blog_editor.id})

      assert {:ok, _} = CMS.create_post(%{title: "P", slug: slug()}, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_page(%{title: "Pg", slug: slug()}, actor: editor)
    end

    test "the role bundles all three axes" do
      admin = user(:admin)
      draft = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: admin)
      post = CMS.create_post!(%{title: "P", slug: slug()}, actor: admin)

      bundle =
        seed_role(%{readable_types: ["post"], field_grants: %{"post" => ["title"]}})

      editor = user(:editor)
      membership(editor, %{role_id: bundle.id})

      # readable_types via role: page drafts invisible.
      refute draft.id in (CMS.list_pages!(actor: editor) |> Enum.map(& &1.id))

      # field_grants via role: only title changes allowed on posts.
      assert {:ok, post} = CMS.update_post(post, %{title: "Renamed"}, actor: editor)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.update_post(post, %{excerpt: "Nope"}, actor: editor)
    end

    test "a membership's own scope overrides its role per axis" do
      role = seed_role(%{editable_types: ["post"]})
      editor = user(:editor)
      # The member-level override widens this member to pages despite the role.
      membership(editor, %{role_id: role.id, editable_types: ["page"]})

      assert {:ok, _} = CMS.create_page(%{title: "Pg", slug: slug()}, actor: editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_post(%{title: "P", slug: slug()}, actor: editor)
    end

    test "deleting a role falls memberships back to their own scope" do
      role = seed_role(%{editable_types: ["post"]})
      admin = user(:admin)
      editor = user(:editor)
      membership(editor, %{role_id: role.id})

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_page(%{title: "Pg", slug: slug()}, actor: editor)

      :ok = Accounts.destroy_role(role, actor: admin)

      assert {:ok, _} = CMS.create_page(%{title: "Pg", slug: slug()}, actor: editor)
    end
  end
end
