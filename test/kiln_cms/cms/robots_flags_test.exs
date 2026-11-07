defmodule KilnCMS.CMS.RobotsFlagsTest do
  @moduledoc """
  The document-level `noindex` / `nofollow` flags (#2256) travel with the
  document: versions, restore, the working copy, a duplicate and a translation.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Duplication
  alias KilnCMS.CMS.Translations
  alias KilnCMS.CMS.VersionDiff
  alias KilnCMS.CMS.WorkingCopy

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "robots-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "robots-#{System.unique_integer([:positive])}"

  defp versions(page, admin) do
    CMS.list_page_versions!(actor: admin)
    |> Enum.filter(&(&1.version_source_id == page.id))
    |> Enum.sort_by(& &1.version_inserted_at, DateTime)
  end

  test "both flags default to false and are writable" do
    admin = admin()
    plain = CMS.create_page!(%{title: "Plain", slug: slug()}, actor: admin)
    assert plain.noindex == false
    assert plain.nofollow == false

    flagged =
      CMS.create_page!(%{title: "Flagged", slug: slug(), noindex: true, nofollow: true},
        actor: admin
      )

    assert flagged.noindex and flagged.nofollow
    assert CMS.update_page!(flagged, %{noindex: false}, actor: admin).noindex == false
  end

  test "an edit is recorded in the version diff, and a restore puts the flags back" do
    admin = admin()
    page = CMS.create_page!(%{title: "V", slug: slug()}, actor: admin)
    page = CMS.update_page!(page, %{noindex: true, nofollow: true}, actor: admin)

    [create_version, edit_version] = versions(page, admin) |> Enum.take(2)

    assert {:ok, a} = fold(page, create_version, admin)
    assert {:ok, b} = fold(page, edit_version, admin)
    diff = VersionDiff.between(a, b, KilnCMS.CMS.Page)

    assert %{status: :changed, old: false, new: true} =
             Enum.find(diff.fields, &(&1.name == :noindex))

    assert Enum.find(diff.fields, &(&1.name == :nofollow))

    restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)
    assert restored.noindex == false
    assert restored.nofollow == false
  end

  test "restoring a version from before the flags existed leaves the current flags alone" do
    admin = admin()
    page = CMS.create_page!(%{title: "Old", slug: slug()}, actor: admin)
    [create_version] = versions(page, admin) |> Enum.take(1)

    # Make the create version look like one written before #2256: no flag keys.
    KilnCMS.Repo.query!(
      "UPDATE pages_versions SET changes = changes - 'noindex' - 'nofollow' WHERE id = $1",
      [Ecto.UUID.dump!(create_version.id)]
    )

    page = CMS.update_page!(page, %{title: "Newer", noindex: true, nofollow: true}, actor: admin)

    restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)

    assert restored.title == "Old"
    assert restored.noindex == true
    assert restored.nofollow == true
  end

  defp fold(page, version, admin) do
    KilnCMS.CMS.VersionSnapshot.at(
      KilnCMS.CMS.Page.Version,
      page.id,
      version,
      actor: admin,
      tenant: page.org_id
    )
  end

  test "a version recorded before the flags existed diffs as false, not as a change" do
    old = %{"title" => "Old"}
    new = %{"title" => "Old", "noindex" => false, "nofollow" => false}

    diff = VersionDiff.between(old, new, KilnCMS.CMS.Page)
    refute Enum.any?(diff.fields, &(&1.name in [:noindex, :nofollow]))

    diff = VersionDiff.between(old, Map.put(new, "noindex", true), KilnCMS.CMS.Page)
    assert %{old: false, new: true} = Enum.find(diff.fields, &(&1.name == :noindex))
  end

  test "a working copy holds the flags until the changes are published" do
    admin = admin()
    page = CMS.create_page!(%{title: "Live", slug: slug()}, actor: admin)
    page = CMS.publish_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    page = CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

    assert {:ok, saved} =
             CMS.save_page_working_copy(page, %{fields: %{"noindex" => true}},
               actor: admin,
               tenant: page.org_id
             )

    assert WorkingCopy.pending?(saved)
    assert WorkingCopy.view(saved).noindex == true
    # The live record still answers false.
    assert CMS.get_page!(page.id, authorize?: false, tenant: page.org_id).noindex == false
  end

  test "a duplicate inherits the flags" do
    admin = admin()

    source =
      CMS.create_page!(%{title: "Src", slug: slug(), noindex: true, nofollow: true}, actor: admin)

    copy = Duplication.duplicate!(:page, source, actor: admin)
    assert copy.noindex and copy.nofollow
  end

  test "a translation copies the flags from its source" do
    admin = admin()

    source =
      CMS.create_page!(%{title: "Src", slug: slug(), locale: "en", noindex: true}, actor: admin)

    fr = Translations.create_translation!(:page, source, "fr", actor: admin)
    assert fr.noindex == true
    assert fr.nofollow == false
  end
end
