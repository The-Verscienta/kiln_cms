defmodule KilnCMS.CMS.RestoreVersionTest do
  @moduledoc """
  `restore_version` reverts a Page/Post's content to a prior PaperTrail
  version (reconstructed by replaying changes_only versions), captured as a new
  version, leaving workflow state untouched.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rv-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "rv-#{System.unique_integer([:positive])}"

  defp versions(page, admin) do
    CMS.list_page_versions!(actor: admin)
    |> Enum.filter(&(&1.version_source_id == page.id))
    |> Enum.sort_by(& &1.version_inserted_at, DateTime)
  end

  test "restores title and blocks to a previous version" do
    admin = admin()

    page =
      CMS.create_page!(
        %{
          title: "Alpha",
          slug: slug(),
          blocks: [%{type: :heading, content: "Original", order: 0}]
        },
        actor: admin
      )

    page =
      CMS.update_page!(
        page,
        %{title: "Beta", blocks: [%{type: :heading, content: "Changed", order: 0}]},
        actor: admin
      )

    page = CMS.update_page!(page, %{title: "Gamma"}, actor: admin)
    assert page.title == "Gamma"

    [create_version | _] = versions(page, admin)

    restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

    assert restored.title == "Alpha"

    # Blocks are stored as the typed union (Kiln v2); read back as legacy maps.
    assert [%{content: "Original"}] =
             restored.blocks
             |> KilnCMS.CMS.TypedBlocks.to_typed()
             |> KilnCMS.CMS.TypedBlocks.to_legacy()
  end

  test "restoring to an intermediate version reconstructs that state" do
    admin = admin()
    page = CMS.create_page!(%{title: "One", slug: slug()}, actor: admin)
    page = CMS.update_page!(page, %{title: "Two"}, actor: admin)
    page = CMS.update_page!(page, %{title: "Three"}, actor: admin)

    [_create, second, _third] = versions(page, admin)

    restored = CMS.restore_page_version!(page, %{version_id: second.id}, actor: admin)
    assert restored.title == "Two"
  end

  test "the restore is itself recorded as a new version" do
    admin = admin()
    page = CMS.create_page!(%{title: "First", slug: slug()}, actor: admin)
    page = CMS.update_page!(page, %{title: "Second"}, actor: admin)

    [create_version | _] = versions(page, admin)
    CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

    # create + update + restore = 3 versions
    assert length(versions(page, admin)) == 3
  end

  test "restoring a coalesced autosave version reconstructs the whole run" do
    admin = admin()
    page = CMS.create_page!(%{title: "Start", slug: slug()}, actor: admin)

    # A run of autosaves touching different fields collapses (issue #32) to a
    # single version — which must still carry the cumulative delta so a restore
    # reconstructs every field, not just the last one changed.
    page = Ash.update!(page, %{title: "Edited title"}, action: :autosave, actor: admin)
    page = Ash.update!(page, %{seo_title: "Edited SEO"}, action: :autosave, actor: admin)
    # Keep the latest record — :restore_version is optimistic-locked (T3.4), so a
    # restore must run against the current lock_version, not a stale reference.
    page = Ash.update!(page, %{slug: "coalesced-slug"}, action: :autosave, actor: admin)

    autosaves = Enum.filter(versions(page, admin), &(&1.version_action_name == :autosave))
    assert length(autosaves) == 1
    [coalesced] = autosaves

    restored = CMS.restore_page_version!(page, %{version_id: coalesced.id}, actor: admin)

    assert restored.title == "Edited title"
    assert restored.seo_title == "Edited SEO"
    assert restored.slug == "coalesced-slug"
  end

  test "rejects a version belonging to a different record" do
    admin = admin()
    page = CMS.create_page!(%{title: "Mine", slug: slug()}, actor: admin)
    other = CMS.create_page!(%{title: "Theirs", slug: slug()}, actor: admin)
    [other_version | _] = versions(other, admin)

    assert {:error, _} =
             CMS.restore_page_version(page, %{version_id: other_version.id}, actor: admin)
  end
end
