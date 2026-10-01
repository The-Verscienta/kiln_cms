defmodule KilnCMS.CMS.WorkingCopyGuardTest do
  @moduledoc """
  The working copy's lost-update guard (#1815).

  A held change is based on a live value. When the live value changes after
  the draft was saved — an API `PATCH`, in-context editing — and the draft
  changed it too, publishing the draft must not silently overwrite the newer
  live value. `:publish_changes` refuses until each such field is decided
  ("mine" / "theirs"); a release blocks the item; fields nobody else touched
  promote as before.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Releases
  alias KilnCMS.CMS.WorkingCopy

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "wcg-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "wcg-#{System.unique_integer([:positive])}"

  defp heading(text), do: %{"_type" => "heading", "text" => text}

  defp reload(page),
    do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id, load: [:tags])

  defp live_page(admin) do
    page =
      CMS.create_page!(
        %{
          title: "Live",
          slug: slug(),
          blocks: [heading("Published body")],
          seo_title: "Live SEO",
          seo_description: "Live description"
        },
        actor: admin
      )

    CMS.publish_page!(page, %{}, actor: admin)
    reload(page)
  end

  defp save_fields(record, fields, actor),
    do: CMS.save_page_working_copy(record, %{fields: fields}, actor: actor, tenant: record.org_id)

  # What an API PATCH does: `:update` on the live row.
  defp live_edit(page, attrs, actor), do: CMS.update_page!(reload(page), attrs, actor: actor)

  defp publish(page, actor, resolve \\ nil) do
    params = if resolve, do: %{resolve: resolve}, else: %{}
    CMS.publish_page_changes(reload(page), params, actor: actor)
  end

  defp delivered(page), do: CMS.get_published_page_by_slug!(page.slug, page.locale)

  describe "no conflict" do
    test "a held field promotes when the live value did not move" do
      admin = user(:admin)
      page = live_page(admin)
      {:ok, _} = save_fields(page, %{"seo_title" => "Mine"}, admin)

      assert WorkingCopy.reconcile(reload(page)).conflicts == []
      assert {:ok, _} = publish(page, admin)
      assert delivered(page).seo_title == "Mine"
    end

    test "a live edit to a field the draft did not change is kept, not reverted" do
      admin = user(:admin)
      page = live_page(admin)
      # The draft changes the SEO title only; its title is the live one.
      {:ok, _} = save_fields(page, %{"seo_title" => "Mine"}, admin)
      live_edit(page, %{title: "Retitled by the API"}, admin)

      assert %{conflicts: [], keep_live: keep} = WorkingCopy.reconcile(reload(page))
      assert "title" in keep

      assert {:ok, _} = publish(page, admin)
      live = delivered(page)
      assert live.title == "Retitled by the API"
      assert live.seo_title == "Mine"
    end
  end

  describe "a live edit after the draft was saved" do
    setup do
      admin = user(:admin)
      page = live_page(admin)

      {:ok, _} =
        save_fields(page, %{"seo_title" => "Mine", "seo_description" => "My description"}, admin)

      # The API changes one of the two held fields on the live page.
      live_edit(page, %{seo_title: "Theirs"}, admin)
      %{admin: admin, page: page}
    end

    test "is surfaced, not overwritten", %{admin: admin, page: page} do
      assert WorkingCopy.reconcile(reload(page)).conflicts == ["seo_title"]

      assert {:error, error} = publish(page, admin)
      assert Exception.message(error) =~ "seo_title"

      live = delivered(page)
      assert live.seo_title == "Theirs"
      assert live.seo_description == "Live description"
      assert WorkingCopy.pending?(reload(page))
    end

    test "keeping theirs drops the held value and promotes the rest", %{admin: admin, page: page} do
      assert {:ok, _} = publish(page, admin, %{"seo_title" => "theirs"})

      live = delivered(page)
      assert live.seo_title == "Theirs"
      assert live.seo_description == "My description"
      refute WorkingCopy.pending?(reload(page))
    end

    test "using mine overwrites, on a decision", %{admin: admin, page: page} do
      assert {:ok, _} = publish(page, admin, %{"*" => "mine"})

      live = delivered(page)
      assert live.seo_title == "Mine"
      assert live.seo_description == "My description"
    end

    test "a release blocks the item and changes nothing", %{admin: admin, page: page} do
      release = CMS.create_release!(%{name: "Launch #{slug()}"}, actor: admin)

      {:ok, item} =
        CMS.add_release_item(
          %{release_id: release.id, content_type: "page", content_id: page.id, action: :publish},
          actor: admin
        )

      live_changed = Releases.live_changed()

      assert Releases.classify(item, authorize?: false, tenant: page.org_id) ==
               {:error, live_changed}

      assert [{_item, {:error, ^live_changed}}] = Releases.readiness(release, actor: admin)

      {:ok, _claimed} = CMS.start_release(release, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert CMS.get_release!(release.id, authorize?: false).state == :failed
      live = delivered(page)
      assert live.seo_title == "Theirs"
      assert live.seo_description == "Live description"
      assert WorkingCopy.pending?(reload(page))
    end

    test "unpublishing keeps the newer live value", %{admin: admin, page: page} do
      {:ok, _} = CMS.unpublish_page(reload(page), %{}, actor: admin)

      draft = reload(page)
      assert draft.seo_title == "Theirs"
      assert draft.seo_description == "My description"
    end
  end

  test "the text is guarded too: an API retitle after the draft retitled it" do
    admin = user(:admin)
    page = live_page(admin)

    {:ok, _} =
      CMS.save_page_working_copy(page, %{working_title: "My title", working_blocks: page.blocks},
        actor: admin,
        tenant: page.org_id
      )

    live_edit(page, %{title: "API title"}, admin)

    assert %{conflicts: ["title"], keep_live: ["blocks"]} = WorkingCopy.reconcile(reload(page))
    assert {:error, _} = publish(page, admin)
    assert {:ok, _} = publish(page, admin, %{"title" => "mine"})
    assert delivered(page).title == "My title"
  end

  test "a tag change on the live page conflicts with a held tag change" do
    admin = user(:admin)
    page = live_page(admin)
    mine = CMS.create_tag!(%{name: "Mine #{slug()}", slug: slug()}, actor: admin)
    theirs = CMS.create_tag!(%{name: "Theirs #{slug()}", slug: slug()}, actor: admin)

    {:ok, _} = save_fields(page, %{"add_tag_ids" => [mine.id]}, admin)
    live_edit(page, %{add_tag_ids: [theirs.id]}, admin)

    assert WorkingCopy.reconcile(reload(page)).conflicts == ["tag_ids"]
    assert {:ok, _} = publish(page, admin, %{"tag_ids" => "theirs"})
    assert Enum.map(reload(page).tags, & &1.id) == [theirs.id]
  end

  test "a copy saved before bases were recorded promotes as it always did" do
    admin = user(:admin)
    page = live_page(admin)
    {:ok, saved} = save_fields(page, %{"seo_title" => "Mine"}, admin)

    # What a row pending from 0.12 / rc.2 looks like: no `working_base`.
    Ash.Seed.update!(saved, %{working_base: %{}})
    live_edit(page, %{seo_title: "Theirs"}, admin)

    assert WorkingCopy.reconcile(reload(page)).conflicts == []
    assert {:ok, _} = publish(page, admin)
    assert delivered(page).seo_title == "Mine"
  end
end
