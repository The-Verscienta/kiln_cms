defmodule KilnCMS.CMS.PublishedVersionTest do
  @moduledoc """
  Publishing records an immutable PaperTrail snapshot via `published_version_id`.
  Unpublishing clears it; subsequent edits do not move the pointer until republish.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pv-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "pv-#{System.unique_integer([:positive])}"

  defp publish_version(page, admin) do
    CMS.list_page_versions!(actor: admin)
    |> Enum.filter(
      &(&1.version_source_id == page.id and
          &1.version_action_name in [:publish, :publish_scheduled])
    )
    |> Enum.sort_by(& &1.version_inserted_at, DateTime)
    |> List.last()
  end

  test "publish sets published_version_id to the publish PaperTrail version" do
    admin = admin()

    page =
      CMS.create_page!(%{title: "Launch", slug: slug()}, actor: admin)

    published = CMS.publish_page!(page, %{}, actor: admin)
    version = publish_version(published, admin)

    assert version
    assert published.published_version_id == version.id
    assert version.version_action_name == :publish
  end

  test "unpublish clears published_version_id" do
    admin = admin()

    page = CMS.create_page!(%{title: "Temp", slug: slug()}, actor: admin)
    page = CMS.publish_page!(page, %{}, actor: admin)
    assert page.published_version_id

    draft = CMS.unpublish_page!(page, %{}, actor: admin)
    assert is_nil(draft.published_version_id)
  end

  test "editing after publish does not change published_version_id until republish" do
    admin = admin()

    page = CMS.create_page!(%{title: "V1", slug: slug()}, actor: admin)
    page = CMS.publish_page!(page, %{}, actor: admin)
    first_version_id = page.published_version_id

    page = CMS.update_page!(page, %{title: "V2"}, actor: admin)
    assert page.published_version_id == first_version_id

    page = CMS.unpublish_page!(page, %{}, actor: admin)
    page = CMS.update_page!(page, %{title: "V3"}, actor: admin)
    republished = CMS.publish_page!(page, %{}, actor: admin)

    assert republished.published_version_id != first_version_id
    assert republished.published_version_id == publish_version(republished, admin).id
  end

  test "scheduled publish records published_version_id" do
    admin = admin()
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    page =
      CMS.create_page!(
        %{title: "Scheduled", slug: slug(), scheduled_at: past},
        actor: admin
      )

    AshOban.schedule_and_run_triggers(KilnCMS.CMS.Page,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    reloaded = CMS.get_page!(page.id, authorize?: false)
    version = publish_version(reloaded, admin)

    assert reloaded.state == :published
    assert reloaded.published_version_id == version.id
    assert version.version_action_name == :publish_scheduled
  end

  test "posts follow the same published_version_id behaviour" do
    admin = admin()

    post = CMS.create_post!(%{title: "Hello", slug: slug()}, actor: admin)
    published = CMS.publish_post!(post, %{}, actor: admin)

    [version] =
      CMS.list_post_versions!(actor: admin)
      |> Enum.filter(&(&1.version_source_id == post.id and &1.version_action_name == :publish))

    assert published.published_version_id == version.id
  end
end
