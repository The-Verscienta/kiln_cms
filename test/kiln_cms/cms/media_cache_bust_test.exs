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

  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.Cache

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
end
