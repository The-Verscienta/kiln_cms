defmodule KilnCMS.CMS.RestoreVersionPlanTest do
  @moduledoc """
  `RestoreVersion.plan/3` / `preview/3` (#2294): the restore, up to but not
  including the write. What a preview reports must be what a real restore
  leaves in the row, and previewing must change nothing.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Changes.RestoreVersion
  alias KilnCMS.CMS.VersionFields
  alias KilnCMS.CMS.VersionSnapshot

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rvp-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "rvp-#{System.unique_integer([:positive])}"

  defp heading(text), do: %{"_type" => "heading", "text" => text}

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp versions(page) do
    CMS.list_page_versions!(authorize?: false, tenant: page.org_id)
    |> Enum.filter(&(&1.version_source_id == page.id))
    |> Enum.sort_by(& &1.version_inserted_at, DateTime)
  end

  defp define_field!(admin, attrs),
    do: CMS.create_field_definition!(Map.put(attrs, :content_type, :page), actor: admin)

  defp preview(page, version, admin),
    do: RestoreVersion.preview(page, version.id, actor: admin, tenant: page.org_id)

  # Compared the way the diff compares: as the JSON-shaped snapshot of a row
  # carrying the previewed values against the restored row's own. Block trees
  # hold structs whose Ecto metadata differs between "built" and "loaded".
  defp assert_matches_restore(plan, restored) do
    restorable = VersionFields.restorable_fields(KilnCMS.CMS.Page)
    previewed = VersionSnapshot.current(struct(restored, plan.values))
    actual = VersionSnapshot.current(restored)

    for name <- restorable do
      key = to_string(name)

      assert Map.fetch!(previewed, key) == Map.fetch!(actual, key),
             "previewed #{name} differs from the restored row"
    end

    assert plan.custom_fields == restored.custom_fields
    assert plan.errors == []
  end

  test "a draft: every restorable key previews as the restore leaves it" do
    admin = admin()
    define_field!(admin, %{name: "price", label: "Price"})
    define_field!(admin, %{name: "sale", label: "On sale", field_type: :boolean})

    page =
      CMS.create_page!(
        %{
          title: "Alpha",
          slug: slug(),
          blocks: [heading("Original")],
          custom_fields: %{"price" => "9"}
        },
        actor: admin
      )

    [create_version | _] = versions(page)

    page =
      CMS.update_page!(
        page,
        %{
          title: "Beta",
          seo_title: "Added later",
          blocks: [heading("Changed")],
          custom_fields: %{"price" => "19", "sale" => true}
        },
        actor: admin
      )

    plan = preview(page, create_version, admin)

    assert plan.values.title == "Alpha"
    assert plan.values.seo_title == nil
    # Drafts carry no working copy.
    assert plan.values.working_title == nil
    assert plan.values.working_blocks == []

    restored = CMS.restore_page_version!(page, %{version_id: create_version.id}, actor: admin)
    assert_matches_restore(plan, restored)
  end

  test "a published record: the working copy is kept, and previews as restored" do
    admin = admin()
    define_field!(admin, %{name: "price", label: "Price"})

    page =
      CMS.create_page!(
        %{
          title: "Live",
          slug: slug(),
          blocks: [heading("Body")],
          custom_fields: %{"price" => "9"}
        },
        actor: admin
      )

    page = CMS.publish_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    page = reload(page)

    {:ok, pending} =
      CMS.save_page_working_copy(
        page,
        %{working_title: "Held title", working_blocks: [heading("Held body")]},
        actor: admin,
        tenant: page.org_id
      )

    held_version =
      Enum.find(versions(page), &(&1.version_action_name == :save_working_copy))

    # An unrelated save between the two, so autosave coalescing leaves the first
    # copy's version alone; then move the working copy on.
    pending = CMS.update_page!(reload(pending), %{seo_title: "Interlude"}, actor: admin)

    {:ok, pending} =
      CMS.save_page_working_copy(
        pending,
        %{working_title: "Newer title", working_blocks: [heading("Newer body")]},
        actor: admin,
        tenant: page.org_id
      )

    plan = preview(pending, held_version, admin)

    assert plan.values.working_title == "Held title"
    assert plan.values.working_copy_at

    restored =
      pending
      |> then(&CMS.restore_page_version!(&1, %{version_id: held_version.id}, actor: admin))
      |> reload()

    assert_matches_restore(plan, restored)
  end

  test "dropped keys name the retired key and exclude the kept ones" do
    admin = admin()
    price = define_field!(admin, %{name: "price", label: "Price"})
    define_field!(admin, %{name: "sale", label: "On sale", field_type: :boolean})

    page =
      CMS.create_page!(
        %{title: "P", slug: slug(), custom_fields: %{"price" => "9", "sale" => true}},
        actor: admin
      )

    [create_version | _] = versions(page)
    page = CMS.update_page!(page, %{title: "P2"}, actor: admin)
    CMS.destroy_field_definition!(price, actor: admin)

    plan = preview(page, create_version, admin)

    assert plan.dropped == ["price"]
    refute Map.has_key?(plan.custom_fields, "price")
    assert plan.custom_fields["sale"] == true
  end

  test "previewing writes nothing" do
    admin = admin()
    page = CMS.create_page!(%{title: "One", slug: slug()}, actor: admin)
    [create_version | _] = versions(page)
    page = CMS.update_page!(page, %{title: "Two"}, actor: admin)

    before_versions = length(versions(page))
    plan = preview(page, create_version, admin)

    assert plan.values.title == "One"
    assert reload(page).title == "Two"
    assert length(versions(page)) == before_versions
  end

  test "a version of another record plans an error and no values to trust" do
    admin = admin()
    page = CMS.create_page!(%{title: "One", slug: slug()}, actor: admin)
    other = CMS.create_page!(%{title: "Other", slug: slug()}, actor: admin)
    [other_version | _] = versions(other)

    plan = preview(page, other_version, admin)

    assert [_ | _] = plan.errors
  end
end
