defmodule KilnCMS.CMS.RedirectPoliciesTest do
  @moduledoc """
  Who may delete a `CMS.Redirect` row. Admins may delete any; the content
  editor's per-record Delete extends that to whoever may **write the
  target** (`Checks.WritesRedirectTarget`) — and to nobody else: a type-scoped
  editor cannot prune a redirect at a type they may not author, a viewer
  cannot prune anything, and a row whose target is gone stays an admin job.
  Creating stays admin-only.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post

  defp user(role, grants \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.Accounts.User,
      Map.merge(
        %{
          email: "redirect-#{role}-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          role: role
        },
        grants
      )
    )
  end

  defp uniq, do: System.unique_integer([:positive])

  defp page, do: Ash.Seed.seed!(Page, %{title: "T", slug: "rp-pg-#{uniq()}", state: :published})
  defp post, do: Ash.Seed.seed!(Post, %{title: "T", slug: "rp-po-#{uniq()}", state: :published})

  defp redirect(target_type, target) do
    CMS.create_redirect!(
      %{
        path: "/retired-#{uniq()}",
        locale: "en",
        target_type: target_type,
        target_id: target.id
      },
      authorize?: false,
      tenant: target.org_id
    )
  end

  defp destroy(redirect, actor) do
    CMS.destroy_redirect(redirect, actor: actor, tenant: redirect.org_id)
  end

  describe "destroy" do
    test "an admin may delete any redirect, including one at a missing target" do
      admin = user(:admin)
      redirect = redirect("page", page())
      assert :ok = destroy(redirect, admin)

      orphan = redirect("page", %{id: Ash.UUID.generate(), org_id: redirect.org_id})
      assert :ok = destroy(orphan, admin)
    end

    test "an editor who may write the target may delete a redirect at it" do
      editor = user(:editor)
      assert :ok = destroy(redirect("page", page()), editor)
      assert :ok = destroy(redirect("post", post()), editor)
    end

    test "a type-scoped editor may delete only at the types they may author" do
      poster = user(:editor, %{editable_types: ["post"]})

      assert :ok = destroy(redirect("post", post()), poster)

      at_page = redirect("page", page())
      assert {:error, %Ash.Error.Forbidden{}} = destroy(at_page, poster)
      assert {:ok, _} = CMS.get_redirect(at_page.id, authorize?: false, tenant: at_page.org_id)
    end

    test "an editor may not delete a redirect whose target is gone or unregistered" do
      editor = user(:editor)
      org_id = page().org_id

      orphan = redirect("page", %{id: Ash.UUID.generate(), org_id: org_id})
      assert {:error, %Ash.Error.Forbidden{}} = destroy(orphan, editor)

      unknown = redirect("no-such-type", %{id: Ash.UUID.generate(), org_id: org_id})
      assert {:error, %Ash.Error.Forbidden{}} = destroy(unknown, editor)
    end

    test "a viewer and an anonymous caller may not delete" do
      redirect = redirect("page", page())

      assert {:error, %Ash.Error.Forbidden{}} = destroy(redirect, user(:viewer))
      assert {:error, %Ash.Error.Forbidden{}} = destroy(redirect, nil)
    end
  end

  describe "create" do
    test "stays admin-only — writing the target does not grant creating rows at it" do
      target = page()

      attrs = %{
        path: "/manual-#{uniq()}",
        locale: "en",
        target_type: "page",
        target_id: target.id
      }

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_redirect(attrs, actor: user(:editor), tenant: target.org_id)

      assert {:ok, _} = CMS.create_redirect(attrs, actor: user(:admin), tenant: target.org_id)
    end
  end
end
