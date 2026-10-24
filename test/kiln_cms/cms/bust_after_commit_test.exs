defmodule KilnCMS.CMS.BustAfterCommitTest do
  @moduledoc """
  `BustContentCache` and `BustTypeRegistry` drop their cache entries after
  the commit, never before it. Busted inside the transaction, a reader in
  between re-caches the pre-write answer for a full TTL — and inside a
  release go-live that window is the length of the go-live.

  The transactions here are wrapped in `KilnCMS.AfterCommit.deferring/1`, as
  `KilnCMS.CMS.Releases` wraps its own, so "inside the transaction" is
  observable: the entry is still cached there, and gone once it commits.
  """
  # async: false — the shared content cache, as `WorkingCopyCacheTest`.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.AfterCommit
  alias KilnCMS.Cache
  alias KilnCMS.CMS
  alias KilnCMS.Repo

  setup do
    Cache.bust_published()

    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "bac-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    %{admin: admin}
  end

  defp cached(org, slug, fallback),
    do: Cache.fetch_published(org, "page", slug, "en", fn -> fallback end)

  test "a published page's cache entry survives until the unpublish commits", %{admin: admin} do
    page =
      CMS.create_page!(%{title: "Live", slug: "bac-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    page = CMS.publish_page!(page, %{}, actor: admin)
    org = page.org_id
    assert :cached = cached(org, page.slug, :cached)

    {:ok, :inside} =
      AfterCommit.deferring(fn ->
        Repo.transaction(fn ->
          CMS.unpublish_page!(page, %{},
            actor: admin,
            context: AfterCommit.context()
          )

          assert :cached = cached(org, page.slug, :fresh)
          :inside
        end)
      end)

    assert :fresh = cached(org, page.slug, :fresh)
  end

  # The test env reads the registry uncached (`cache_registry?: false`), so
  # this watches the cache key `ContentTypes.dynamic_all/1` would use.
  test "a type write busts the registry after the commit", %{admin: admin} do
    org = KilnCMS.Accounts.org_id(nil)

    registry = fn fallback ->
      Cache.fetch(Cache.type_registry_key(org), 60_000, fn -> fallback end)
    end

    assert :primed = registry.(:primed)

    {:ok, :inside} =
      AfterCommit.deferring(fn ->
        Repo.transaction(fn ->
          CMS.create_type_definition!(
            %{name: "bac#{System.unique_integer([:positive])}", label: "Probe"},
            actor: admin,
            context: AfterCommit.context()
          )

          assert :primed = registry.(:fresh)
          :inside
        end)
      end)

    assert :fresh = registry.(:fresh)
  end
end
