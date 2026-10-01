defmodule KilnCMS.CMS.WorkingCopyCacheTest do
  @moduledoc """
  A save to a live page's working copy leaves its cached public page alone
  (#1815): nothing that page serves changed. Publishing the copy busts it.
  """
  # async: false — relies on the shared content cache not being busted by
  # other tests (the cache tests clear it wholesale), as
  # `KilnCMSWeb.ContentCacheTest` does.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Cache
  alias KilnCMS.CMS

  setup do
    Cache.bust_published()
    :ok
  end

  test "a working-copy save keeps the cached page; publishing it busts it" do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "wcc-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    page =
      CMS.create_page!(%{title: "Live", slug: "wcc-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    page = CMS.publish_page!(page, %{}, actor: admin)
    org = page.org_id

    assert :cached = Cache.fetch_published(org, "page", page.slug, "en", fn -> :cached end)

    {:ok, saved} =
      CMS.save_page_working_copy(page, %{fields: %{"seo_title" => "Held"}},
        actor: admin,
        tenant: org
      )

    assert :cached = Cache.fetch_published(org, "page", page.slug, "en", fn -> :fresh end)

    {:ok, _} = CMS.publish_page_changes(saved, actor: admin)
    assert :fresh = Cache.fetch_published(org, "page", page.slug, "en", fn -> :fresh end)
  end
end
