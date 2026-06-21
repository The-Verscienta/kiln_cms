defmodule KilnCMS.CMS.PoliciesTest do
  @moduledoc """
  RBAC policy coverage for the CMS resources (Page/Post/MediaItem).

  Verifies the core security guarantees: unauthenticated/viewer reads are
  limited to published content, editors can author but not hard-delete, and
  admins bypass everything.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
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
    Ash.Seed.seed!(
      Page,
      Map.merge(%{title: "T", slug: "s-#{System.unique_integer([:positive])}"}, attrs)
    )
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
      ids = CMS.list_pages!(authorize?: true) |> Enum.map(& &1.id)
      assert ids == [published.id]
    end

    test "viewer sees only published", %{viewer: viewer, published: published} do
      ids = CMS.list_pages!(actor: viewer) |> Enum.map(& &1.id)
      assert ids == [published.id]
    end

    test "editor sees published and unpublished", %{
      editor: editor,
      published: published,
      draft: draft
    } do
      ids = CMS.list_pages!(actor: editor) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([published.id, draft.id])
    end

    test "admin sees everything", %{admin: admin, published: published, draft: draft} do
      ids = CMS.list_pages!(actor: admin) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([published.id, draft.id])
    end
  end

  describe "write authorization by role" do
    # Uses the `can_*?/2` authorization helpers Ash generates from the domain
    # code interfaces.
    test "editors may create, viewers may not", %{editor: editor, viewer: viewer} do
      assert CMS.can_create_page?(editor)
      refute CMS.can_create_page?(viewer)
    end

    test "editors may update, viewers may not", %{editor: editor, viewer: viewer, draft: draft} do
      assert CMS.can_update_page?(editor, draft)
      refute CMS.can_update_page?(viewer, draft)
    end

    test "only admins may destroy", %{admin: admin, editor: editor, draft: draft} do
      assert CMS.can_destroy_page?(admin, draft)
      refute CMS.can_destroy_page?(editor, draft)
    end
  end
end
