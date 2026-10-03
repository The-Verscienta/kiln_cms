defmodule KilnCMS.CMS.SavedViewTest do
  @moduledoc """
  Saved views on the content list (#1593): the code interfaces, the params
  the resource keeps, and who may read and change which view.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Organization
  alias KilnCMS.CMS
  alias KilnCMS.CMS.SavedView

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "views-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org do
    Ash.Seed.seed!(Organization, %{
      name: "Views #{System.unique_integer([:positive])}",
      slug: "views-#{System.unique_integer([:positive])}"
    })
  end

  defp membership(user, org, tier) do
    Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })
  end

  defp tenant, do: Accounts.default_org_id()

  defp save!(actor, attrs) do
    CMS.create_saved_view!(
      Map.merge(%{name: "Drafts", params: %{"status" => "draft"}}, attrs),
      actor: actor,
      tenant: tenant()
    )
  end

  defp names(actor, opts \\ []) do
    actor
    |> then(&CMS.list_saved_views!(Keyword.merge([actor: &1, tenant: tenant()], opts)))
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  describe "create" do
    test "stamps the actor as owner and keeps only the list's own params" do
      editor = user(:editor)

      view =
        save!(editor, %{
          name: "  Mine  ",
          params: %{
            "status" => "draft",
            "author" => "me",
            "q" => "  launch ",
            "page" => "3",
            "status_extra" => "x",
            "tag" => ["a list"],
            "locale" => ""
          }
        })

      assert view.owner_id == editor.id
      assert view.name == "Mine"
      assert view.shared == false
      assert view.params == %{"status" => "draft", "author" => "me", "q" => "launch"}
    end

    test "a name is required" do
      editor = user(:editor)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.create_saved_view(%{name: "  ", params: %{}}, actor: editor, tenant: tenant())
    end

    test "an editor cannot share a view; an admin can" do
      editor = user(:editor)
      admin = user(:admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_saved_view(%{name: "Team", params: %{}, shared: true},
                 actor: editor,
                 tenant: tenant()
               )

      assert %SavedView{shared: true} = save!(admin, %{name: "Team", shared: true})
    end

    test "a viewer cannot save a view" do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_saved_view(%{name: "Nope", params: %{}},
                 actor: user(:viewer),
                 tenant: tenant()
               )
    end
  end

  describe "visible" do
    test "lists the actor's own views and the shared ones, never another editor's private one" do
      owner = user(:editor)
      other = user(:editor)
      admin = user(:admin)

      save!(owner, %{name: "Owner private"})
      save!(other, %{name: "Other private"})
      save!(admin, %{name: "Team view", shared: true})

      assert names(owner) == ["Owner private", "Team view"]
      assert names(other) == ["Other private", "Team view"]
    end

    test "an admin's list is their own and the shared views, but they can reach any view" do
      owner = user(:editor)
      admin = user(:admin)
      view = save!(owner, %{name: "Owner private"})

      # `:visible` is "own or shared" for everyone, so an admin's console is
      # not crowded with every editor's private views…
      refute "Owner private" in names(admin)

      # …but the bypass lets them read (and so manage) any one of them.
      assert {:ok, %SavedView{name: "Owner private"}} =
               CMS.get_saved_view(view.id, actor: admin, tenant: tenant())
    end

    test "a viewer sees nothing, shared or not" do
      admin = user(:admin)
      save!(admin, %{name: "Team view", shared: true})

      assert names(user(:viewer)) == []
    end

    test "another editor cannot fetch a private view by id" do
      owner = user(:editor)
      view = save!(owner, %{name: "Owner private"})

      assert {:error, _} = CMS.get_saved_view(view.id, actor: user(:editor), tenant: tenant())
    end

    test "views do not cross sites" do
      site = org()
      editor = user(:viewer)
      membership(editor, site, :editor)

      CMS.create_saved_view!(%{name: "On site", params: %{}}, actor: editor, tenant: site)

      admin = user(:admin)

      CMS.create_saved_view!(%{name: "Shared on site", params: %{}, shared: true},
        actor: admin,
        tenant: site
      )

      assert names(editor, tenant: site) == ["On site", "Shared on site"]
      # The platform admin, on the default site, sees neither.
      refute Enum.any?(names(admin), &(&1 in ["On site", "Shared on site"]))
    end
  end

  describe "update and destroy" do
    test "the owner renames and deletes their private view" do
      owner = user(:editor)
      view = save!(owner, %{})

      assert {:ok, %SavedView{name: "Renamed"}} =
               CMS.update_saved_view(view, %{name: "Renamed"}, actor: owner, tenant: tenant())

      assert :ok = CMS.destroy_saved_view(view, actor: owner, tenant: tenant())
      assert names(owner) == []
    end

    test "another editor can neither rename nor delete it" do
      owner = user(:editor)
      other = user(:editor)
      view = save!(owner, %{})

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_saved_view(view, %{name: "Mine now"}, actor: other, tenant: tenant())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_saved_view(view, actor: other, tenant: tenant())

      refute CMS.can_update_saved_view?(other, view, %{}, tenant: tenant())
      assert CMS.can_update_saved_view?(owner, view, %{}, tenant: tenant())
    end

    test "an editor cannot share their own view by updating it" do
      owner = user(:editor)
      view = save!(owner, %{})

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_saved_view(view, %{shared: true}, actor: owner, tenant: tenant())

      assert CMS.get_saved_view!(view.id, actor: owner, tenant: tenant()).shared == false
    end

    test "a shared view is the admin's to change, even when an editor owns it" do
      owner = user(:editor)
      admin = user(:admin)
      view = save!(owner, %{})

      # The admin pins the editor's view for the team.
      view = CMS.update_saved_view!(view, %{shared: true}, actor: admin, tenant: tenant())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_saved_view(view, %{name: "Hijacked"}, actor: owner, tenant: tenant())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_saved_view(view, actor: owner, tenant: tenant())

      assert :ok = CMS.destroy_saved_view(view, actor: admin, tenant: tenant())
    end

    test "an admin can rename and delete another editor's private view" do
      owner = user(:editor)
      admin = user(:admin)
      view = save!(owner, %{})

      assert {:ok, _} =
               CMS.update_saved_view(view, %{name: "Tidied"}, actor: admin, tenant: tenant())

      assert :ok = CMS.destroy_saved_view(view, actor: admin, tenant: tenant())
    end

    test "updating params cleans them the same way create does" do
      owner = user(:editor)
      view = save!(owner, %{})

      view =
        CMS.update_saved_view!(view, %{params: %{"sort" => "title", "evil" => "1"}},
          actor: owner,
          tenant: tenant()
        )

      assert view.params == %{"sort" => "title"}
    end
  end

  test "deleting the owner deletes their views" do
    owner = user(:editor)
    view = save!(owner, %{})

    KilnCMS.Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(owner.id)])

    assert {:error, _} = CMS.get_saved_view(view.id, authorize?: false, tenant: tenant())
  end

  test "clean_params/1 tolerates anything" do
    assert SavedView.clean_params(nil) == %{}
    assert SavedView.clean_params(%{status: "draft"}) == %{"status" => "draft"}
    assert SavedView.clean_params(%{"q" => String.duplicate("a", 201)}) == %{}
  end
end
