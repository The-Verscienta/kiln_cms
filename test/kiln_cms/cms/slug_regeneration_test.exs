defmodule KilnCMS.CMS.SlugRegenerationTest do
  @moduledoc """
  Bulk slug regeneration (#455): preview/run share one traversal; hand-picked
  slugs are skipped unless included; renames route through the normal
  `:update` action so published renames leave 301 redirects; pattern changes
  migrate existing entries with `include_pinned`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.SlugRegeneration

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "regen-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp org, do: KilnCMS.Accounts.default_org_id()

  test "a stale title-derived slug looks hand-picked: skipped by default, renamed when included" do
    admin = user(:admin)
    page = CMS.create_page!(%{title: "A Guide to the Kiln Regen"}, actor: admin)
    assert page.slug == "guide-kiln-regen"

    # A title-only PATCH (headless-style) leaves the slug stale.
    CMS.update_page!(page, %{title: "Completely New Name Regen"}, actor: admin)

    default = SlugRegeneration.preview(:page, org())
    assert default.changes == []
    assert default.pinned_skipped >= 1

    included = SlugRegeneration.preview(:page, org(), include_pinned: true)
    assert %{current: "guide-kiln-regen", new: "completely-new-name-regen"} = hd(included.changes)

    summary = SlugRegeneration.run(:page, org(), include_pinned: true, actor: admin)
    assert summary.changed >= 1
    assert CMS.get_page!(page.id, actor: admin).slug == "completely-new-name-regen"
  end

  test "dedupe cleanup respects trashed competitors and frees up after purge" do
    admin = user(:admin)
    first = CMS.create_page!(%{title: "Dedupe Regen Case"}, actor: admin)
    second = CMS.create_page!(%{title: "Dedupe Regen Case"}, actor: admin)
    assert second.slug == "dedupe-regen-case-2"

    # Trashed competitor still holds the name in the unique index — no rename.
    CMS.destroy_page!(first, actor: admin)
    summary = SlugRegeneration.run(:page, org(), actor: admin)
    refute Enum.any?(summary.changes, &(&1.id == second.id))

    # Purged for real — the -2 suffix is now unnecessary and gets cleaned up.
    CMS.purge_page!(first, actor: admin)
    summary = SlugRegeneration.run(:page, org(), actor: admin)
    assert Enum.any?(summary.changes, &(&1.new == "dedupe-regen-case"))
    assert CMS.get_page!(second.id, actor: admin).slug == "dedupe-regen-case"
  end

  test "renaming a published record leaves a 301 behind" do
    admin = user(:admin)
    page = CMS.create_page!(%{title: "Published Regen Before"}, actor: admin)
    old_slug = page.slug
    published = CMS.publish_page!(page, %{}, actor: admin)
    CMS.update_page!(published, %{title: "Published Regen After"}, actor: admin)

    summary = SlugRegeneration.run(:page, org(), include_pinned: true, actor: admin)
    assert Enum.any?(summary.changes, &(&1.id == page.id))

    assert [redirect] =
             CMS.list_redirects!(authorize?: false, query: [filter: [path: "/#{old_slug}"]])

    assert redirect.target_id == page.id
  end

  test "a new slug pattern migrates existing entries with include_pinned" do
    admin = user(:admin)

    type =
      CMS.create_type_definition!(
        %{name: "regen#{System.unique_integer([:positive])}", label: "Regen"},
        actor: admin
      )

    entry = ContentTypes.create!(type.name, %{title: "Old Convention Post"}, actor: admin)
    assert entry.slug == "old-convention-post"

    CMS.update_type_definition!(type, %{slug_pattern: "[yyyy]-[title]"}, actor: admin)

    # Under the new pattern every old slug looks hand-picked.
    assert SlugRegeneration.preview(type.name, org()).changes == []

    summary = SlugRegeneration.run(type.name, org(), include_pinned: true, actor: admin)
    year = Date.utc_today().year
    assert [%{new: new}] = summary.changes
    assert new == "#{year}-old-convention-post"

    assert ContentTypes.get_record!(type.name, entry.id, actor: admin).slug == new
  end

  test "author-pinned slugs survive even a full include_pinned run only by explicit choice" do
    admin = user(:admin)
    pinned = CMS.create_page!(%{title: "Keep Me", slug: "totally-custom-regen"}, actor: admin)

    # Default: untouched and counted.
    default = SlugRegeneration.run(:page, org(), actor: admin)
    assert default.pinned_skipped >= 1
    assert CMS.get_page!(pinned.id, actor: admin).slug == "totally-custom-regen"

    # include_pinned deliberately regenerates it.
    SlugRegeneration.run(:page, org(), include_pinned: true, actor: admin)
    assert CMS.get_page!(pinned.id, actor: admin).slug == "keep-me"
  end
end
