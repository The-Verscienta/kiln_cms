defmodule KilnCMS.Seo.Checks.IndexabilityTest do
  @moduledoc """
  The #2256 advisory: a published page a menu links to but that is hidden from
  search. Unit tests drive the check; the last block drives the editor's fact
  through real menu items (enabled, disabled) end to end.
  """
  use KilnCMS.DataCase, async: true

  alias Kiln.Advisory.Context
  alias Kiln.Advisory.Walk
  alias KilnCMS.CMS
  alias KilnCMS.Seo.Checks.Indexability

  defp findings(fields, facts) do
    fields
    |> Context.new(Walk.compute([]), facts: facts)
    |> Indexability.check()
    |> Enum.filter(&match?(%Kiln.Advisory.Finding{}, &1))
  end

  describe "check/1" do
    test "fires when published, nav-linked and noindex" do
      assert [%{code: :noindex_nav_linked, severity: :warning, field: :noindex}] =
               findings(%{state: :published, noindex: true}, %{nav_linked?: true})
    end

    test "is quiet for a draft, an unlinked page, nofollow alone and an indexable page" do
      assert [] = findings(%{state: :draft, noindex: true}, %{nav_linked?: true})
      assert [] = findings(%{state: :published, noindex: true}, %{nav_linked?: false})

      assert [] =
               findings(%{state: :published, nofollow: true, noindex: false}, %{nav_linked?: true})

      assert [] = findings(%{state: :published, noindex: false}, %{nav_linked?: true})
    end

    test "is not applicable without the fact" do
      assert [] = findings(%{state: :published, noindex: true}, %{})
    end
  end

  describe "the menu fact" do
    defp admin do
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "idx-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })
    end

    defp linked?(page, visible) do
      admin = admin()

      menu =
        CMS.create_menu!(
          %{key: "m#{System.unique_integer([:positive])}", locale: "en", name: "Main"},
          actor: admin
        )

      CMS.create_menu_item!(
        %{
          menu_id: menu.id,
          label: "L",
          link_type: :content,
          target_type: "page",
          target_id: page.id,
          visible: visible
        },
        actor: admin
      )

      page.org_id |> KilnCMS.CMS.Menus.linked_content_ids() |> MapSet.member?(page.id)
    end

    test "an enabled menu item counts, a hidden one does not" do
      admin = admin()

      page =
        CMS.create_page!(
          %{title: "P", slug: "idx-#{System.unique_integer([:positive])}", noindex: true},
          actor: admin
        )

      refute linked?(page, false)
      assert linked?(page, true)
    end
  end
end
