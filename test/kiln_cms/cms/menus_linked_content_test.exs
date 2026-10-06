defmodule KilnCMS.CMS.MenusLinkedContentTest do
  @moduledoc """
  Which documents the site's menus actually link to (#1597, D21) — the question
  behind the structure view's "not in any menu" badge.

  A menu item only makes its target reachable if it would **render**, so the
  rules each get pinned: content items only, visible itself and all the way up,
  and rooted within its menu.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Menus

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "lnk-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp page(actor) do
    CMS.create_page!(
      %{title: "P", slug: "lnk-#{System.unique_integer([:positive])}"},
      actor: actor
    )
  end

  defp menu(actor) do
    CMS.create_menu!(
      %{key: "m#{System.unique_integer([:positive])}", locale: "en", name: "Main"},
      actor: actor
    )
  end

  defp item(actor, menu, attrs) do
    CMS.create_menu_item!(
      Map.merge(%{menu_id: menu.id, label: "L", link_type: :content}, attrs),
      actor: actor
    )
  end

  defp linked(record), do: Menus.linked_content_ids(record.org_id)

  test "a visible, rooted content item links its target" do
    actor = admin()
    target = page(actor)
    item(actor, menu(actor), %{target_type: "page", target_id: target.id})

    assert MapSet.member?(linked(target), target.id)
  end

  test "a document nothing points at is not linked" do
    actor = admin()
    target = page(actor)
    _unrelated = menu(actor)

    refute MapSet.member?(linked(target), target.id)
  end

  test "a hidden item is not a way in" do
    actor = admin()
    target = page(actor)
    item(actor, menu(actor), %{target_type: "page", target_id: target.id, visible: false})

    refute MapSet.member?(linked(target), target.id)
  end

  test "a visible item under a hidden parent is not a way in either" do
    actor = admin()
    target = page(actor)
    m = menu(actor)
    section = item(actor, m, %{label: "Section", link_type: :none, visible: false})
    item(actor, m, %{target_type: "page", target_id: target.id, parent_id: section.id})

    # The item renders nowhere, because the section it lives in is switched off.
    refute MapSet.member?(linked(target), target.id)
  end

  test "a detached item links nothing — it never renders" do
    actor = admin()
    target = page(actor)
    m = menu(actor)
    parent = item(actor, m, %{label: "Parent", link_type: :none})
    child = item(actor, m, %{target_type: "page", target_id: target.id, parent_id: parent.id})

    assert MapSet.member?(linked(target), target.id)

    # Destroying the parent orphans the child's chain; it can no longer be
    # reached from a root, so it stops linking its target.
    CMS.destroy_menu_item!(parent, actor: actor)

    refute MapSet.member?(linked(target), target.id)
  end

  test "a :url item pointing at the same page is not a tracked link" do
    actor = admin()
    target = page(actor)
    item(actor, menu(actor), %{link_type: :url, url: "/#{target.slug}"})

    # Nothing records that this URL is that document, so it cannot count.
    refute MapSet.member?(linked(target), target.id)
  end

  test "linked from any menu counts as linked" do
    actor = admin()
    target = page(actor)
    _first = menu(actor)
    second = menu(actor)
    item(actor, second, %{target_type: "page", target_id: target.id})

    assert MapSet.member?(linked(target), target.id)
  end
end
