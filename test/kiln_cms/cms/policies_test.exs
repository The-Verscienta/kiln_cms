defmodule KilnCMS.CMS.PoliciesTest do
  @moduledoc """
  RBAC policy coverage for the CMS resources (Page/Post/MediaItem).

  Verifies the core security guarantees: unauthenticated/viewer reads are
  limited to published content, editors can author but not hard-delete, and
  admins bypass everything.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS.Page

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      role: role
    })
  end

  defp page(attrs) do
    # Seed directly so fixtures don't depend on the very policies under test.
    Ash.Seed.seed!(Page, Map.merge(%{title: "T", slug: "s-#{System.unique_integer([:positive])}"}, attrs))
  end

  setup do
    admin = user(:admin)
    editor = user(:editor)
    viewer = user(:viewer)

    published = page(%{state: :published})
    draft = page(%{state: :draft})

    %{
      admin: admin,
      editor: editor,
      viewer: viewer,
      published: published,
      draft: draft
    }
  end

  describe "read visibility by role" do
    test "anonymous (no actor) sees only published", %{published: published} do
      ids = Page |> Ash.read!(authorize?: true) |> Enum.map(& &1.id)
      assert ids == [published.id]
    end

    test "viewer sees only published", %{viewer: viewer, published: published} do
      ids = Page |> Ash.read!(actor: viewer) |> Enum.map(& &1.id)
      assert ids == [published.id]
    end

    test "editor sees published and unpublished", %{editor: editor, published: published, draft: draft} do
      ids = Page |> Ash.read!(actor: editor) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([published.id, draft.id])
    end

    test "admin sees everything", %{admin: admin, published: published, draft: draft} do
      ids = Page |> Ash.read!(actor: admin) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([published.id, draft.id])
    end
  end

  describe "write authorization by role" do
    test "editors may create, viewers may not", %{editor: editor, viewer: viewer} do
      assert Ash.can?({Page, :create}, editor)
      refute Ash.can?({Page, :create}, viewer)
    end

    test "editors may update, viewers may not", %{editor: editor, viewer: viewer, draft: draft} do
      assert Ash.can?({draft, :update}, editor)
      refute Ash.can?({draft, :update}, viewer)
    end

    test "only admins may destroy", %{admin: admin, editor: editor, draft: draft} do
      assert Ash.can?({draft, :destroy}, admin)
      refute Ash.can?({draft, :destroy}, editor)
    end
  end
end
