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
        %{title: "Beta", blocks: [%{type: :heading, content: "Changed", order: 0}]}, actor: admin)

    page = CMS.update_page!(page, %{title: "Gamma"}, actor: admin)
    assert page.title == "Gamma"

    [create_version | _] = versions(page, admin)

    restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

    assert restored.title == "Alpha"
    assert [%{content: "Original"}] = restored.blocks
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

  test "rejects a version belonging to a different record" do
    admin = admin()
    page = CMS.create_page!(%{title: "Mine", slug: slug()}, actor: admin)
    other = CMS.create_page!(%{title: "Theirs", slug: slug()}, actor: admin)
    [other_version | _] = versions(other, admin)

    assert {:error, _} =
             CMS.restore_page_version(page, %{version_id: other_version.id}, actor: admin)
  end
end
