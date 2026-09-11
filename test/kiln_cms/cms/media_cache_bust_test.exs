defmodule KilnCMS.CMS.MediaCacheBustTest do
  @moduledoc """
  `KilnCMS.CMS.Changes.BustMediaCache` should fire on a media write that can
  affect rendered pages (alt/dimensions/variants/storage/focal/audience/
  decorative/content-type, or create/destroy/purge) and must NOT fire on an
  attribute-only write like `download_count` (#1137) — a popular download
  would otherwise keep the delivery cache permanently cold.

  Probes with `Cache.fetch_published/5` rather than touching Cachex directly,
  the same idiom `KilnCMS.CacheTest` uses: prime a cached value, perform the
  write, and check whether the next fetch recomputes (busted) or still
  returns the primed value (not busted).
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Cache
  alias KilnCMS.CMS.MediaItem

  defp media! do
    Ash.Seed.seed!(MediaItem, %{
      filename: "hero-#{System.unique_integer([:positive])}.png",
      url: "/uploads/hero.png",
      alt: "A hero image"
    })
  end

  defp slug, do: "media-bust-#{System.unique_integer([:positive])}"

  defp prime do
    s = slug()

    assert :v1 =
             Cache.fetch_published(KilnCMS.Accounts.default_org_id(), "page", s, "en", fn ->
               :v1
             end)

    s
  end

  defp busted?(s) do
    Cache.fetch_published(KilnCMS.Accounts.default_org_id(), "page", s, "en", fn -> :v2 end) ==
      :v2
  end

  test "download_count alone does not bust the cache" do
    media = media!()
    s = prime()

    Ash.update!(media, %{}, action: :increment_downloads, authorize?: false)

    refute busted?(s)
  end

  test "an alt-text edit busts the cache" do
    media = media!()
    s = prime()

    Ash.update!(media, %{alt: "A different hero image"}, authorize?: false)

    assert busted?(s)
  end

  test "a dimension edit busts the cache" do
    media = media!()
    s = prime()

    Ash.update!(media, %{width: 640, height: 480}, authorize?: false)

    assert busted?(s)
  end

  test "a decorative-flag edit busts the cache" do
    media = media!()
    s = prime()

    Ash.update!(media, %{decorative: true}, authorize?: false)

    assert busted?(s)
  end

  test "a create busts the cache" do
    s = prime()

    Ash.create!(MediaItem, %{filename: "new-#{System.unique_integer([:positive])}.png"},
      authorize?: false
    )

    assert busted?(s)
  end

  test "a destroy busts the cache" do
    media = media!()
    s = prime()

    Ash.destroy!(media, authorize?: false)

    assert busted?(s)
  end

  test "a purge busts the cache" do
    media = media!()
    s = prime()

    Ash.destroy!(media, action: :purge, authorize?: false)

    assert busted?(s)
  end

  # The bulk-delete opt-out (#1316 review): a caller deleting N items clears
  # once after its loop instead of N times, so the per-record change must
  # stand down when told to. The flag's contract is "the caller owns the
  # single post-loop bust".
  test "a destroy with skip_media_cache_bust does not bust the cache" do
    media = media!()
    s = prime()

    # Through the code interface, as the library's bulk delete calls it.
    :ok =
      KilnCMS.CMS.destroy_media_item!(media,
        authorize?: false,
        context: %{skip_media_cache_bust: true}
      )

    refute busted?(s)
  end

  # …and the compensating half of that contract: `Media.Bulk.delete/2` (the
  # library's bulk-delete owner) must actually issue the single clear —
  # without this, dropping its post-loop bust would leave every bulk-deleted
  # item serving from the published cache with the suite green.
  test "Media.Bulk.delete busts the cache once for the whole batch" do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "bulk-bust-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    a = media!()
    b = media!()
    s = prime()

    assert {2, 0} = KilnCMS.Media.Bulk.delete([a, b], actor: admin)

    assert busted?(s)
  end

  # …and a fully-failed batch must NOT clear a cache nothing changed.
  test "Media.Bulk.delete leaves the cache warm when nothing was destroyed" do
    viewer =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "bulk-nobust-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    a = media!()
    s = prime()

    assert {0, 1} = KilnCMS.Media.Bulk.delete([a], actor: viewer)

    refute busted?(s)
  end

  # The create-side twin (#1316 review): a batch upload/import defers its
  # per-item clears and issues one bust after the loop.
  test "a create with skip_media_cache_bust does not bust the cache" do
    s = prime()

    KilnCMS.CMS.create_media_item!(
      %{filename: "defer.png", url: "/uploads/defer-#{System.unique_integer([:positive])}"},
      authorize?: false,
      context: %{skip_media_cache_bust: true}
    )

    refute busted?(s)
  end
end
