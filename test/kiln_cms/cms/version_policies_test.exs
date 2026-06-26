defmodule KilnCMS.CMS.VersionPoliciesTest do
  @moduledoc """
  RBAC policy coverage for AshPaperTrail version resources (Page/Post).

  Version history must not leak draft content to anonymous users or viewers.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "#{role}-ver-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  setup do
    admin = user(:admin)
    editor = user(:editor)
    viewer = user(:viewer)

    slug = "ver-#{System.unique_integer([:positive])}"

    page =
      CMS.create_page!(
        %{title: "Versioned", slug: slug},
        actor: admin
      )

    %{
      admin: admin,
      editor: editor,
      viewer: viewer,
      page: page
    }
  end

  describe "page version read visibility" do
    test "anonymous users cannot read version history", %{page: page} do
      assert {:ok, versions} = CMS.list_page_versions(authorize?: false)
      assert Enum.any?(versions, &(&1.version_source_id == page.id))

      assert {:ok, []} = CMS.list_page_versions(authorize?: true)
    end

    test "viewers cannot read version history", %{viewer: viewer, page: page} do
      assert {:ok, versions} = CMS.list_page_versions(authorize?: false)
      assert Enum.any?(versions, &(&1.version_source_id == page.id))

      assert {:ok, []} = CMS.list_page_versions(actor: viewer)
    end

    test "editors can read version history", %{editor: editor, page: page} do
      versions = CMS.list_page_versions!(actor: editor)
      assert Enum.any?(versions, &(&1.version_source_id == page.id))
    end

    test "admins can read version history", %{admin: admin, page: page} do
      versions = CMS.list_page_versions!(actor: admin)
      assert Enum.any?(versions, &(&1.version_source_id == page.id))
    end
  end

  describe "post version read visibility" do
    test "anonymous users cannot read post version history", %{admin: admin} do
      post =
        CMS.create_post!(
          %{
            title: "Post Versioned",
            slug: "post-ver-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      assert {:ok, versions} = CMS.list_post_versions(authorize?: false)
      assert Enum.any?(versions, &(&1.version_source_id == post.id))

      assert {:ok, []} = CMS.list_post_versions(authorize?: true)
    end

    test "editors can read post version history", %{editor: editor, admin: admin} do
      post =
        CMS.create_post!(
          %{
            title: "Post Versioned",
            slug: "post-ver-#{System.unique_integer([:positive])}"
          },
          actor: admin
        )

      versions = CMS.list_post_versions!(actor: editor)
      assert Enum.any?(versions, &(&1.version_source_id == post.id))
    end
  end

  describe "manual version mutation" do
    # Version rows are written only by AshPaperTrail (`authorize?: false`).
    # `forbid_if always()` denies manual create/update to every non-admin role,
    # so editors (who *can* read history) still can't forge a version.
    test "editors and viewers cannot create versions manually", %{
      editor: editor,
      viewer: viewer
    } do
      refute Ash.can?({KilnCMS.CMS.Page.Version, :create}, editor)
      refute Ash.can?({KilnCMS.CMS.Page.Version, :create}, viewer)
      refute Ash.can?({KilnCMS.CMS.Post.Version, :create}, editor)
    end
  end
end
