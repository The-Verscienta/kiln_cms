defmodule KilnCMS.CacheTest do
  @moduledoc false
  # async: false — exercises the shared, app-wide content cache.
  use ExUnit.Case, async: false

  alias KilnCMS.Cache

  setup do
    Cache.bust_published()
    :ok
  end

  defp slug, do: "cache-#{System.unique_integer([:positive])}"

  test "caches a computed value and serves it on the next fetch" do
    s = slug()

    assert :first = Cache.fetch_published("page", s, "en", fn -> :first end)
    # The fallback would return :second, but the cached :first wins.
    assert :first = Cache.fetch_published("page", s, "en", fn -> :second end)
  end

  test "does not cache a nil (not-found) result" do
    s = slug()

    assert nil == Cache.fetch_published("page", s, "en", fn -> nil end)
    # Still recomputed, so newly published content shows up immediately.
    assert :now_here = Cache.fetch_published("page", s, "en", fn -> :now_here end)
  end

  test "bust_published clears cached entries" do
    s = slug()

    assert :v1 = Cache.fetch_published("page", s, "en", fn -> :v1 end)
    Cache.bust_published()
    assert :v2 = Cache.fetch_published("page", s, "en", fn -> :v2 end)
  end

  test "keys are namespaced by type and locale" do
    s = slug()

    assert :page = Cache.fetch_published("page", s, "en", fn -> :page end)
    assert :post = Cache.fetch_published("post", s, "en", fn -> :post end)
    # Same type+slug, different locale → a separate entry.
    assert :fr = Cache.fetch_published("page", s, "fr", fn -> :fr end)
  end

  test "bust/2 drops every locale variant of one record, leaving others intact" do
    s = slug()
    other = slug()

    # Cache the same slug under two locales, plus an unrelated slug.
    assert :en = Cache.fetch_published("page", s, "en", fn -> :en end)
    assert :fr = Cache.fetch_published("page", s, "fr", fn -> :fr end)
    assert :keep = Cache.fetch_published("page", other, "en", fn -> :keep end)

    Cache.bust("page", s)

    # Both locale variants of the busted record are recomputed…
    assert :en2 = Cache.fetch_published("page", s, "en", fn -> :en2 end)
    assert :fr2 = Cache.fetch_published("page", s, "fr", fn -> :fr2 end)
    # …while the unrelated record is still served from cache.
    assert :keep = Cache.fetch_published("page", other, "en", fn -> :ignored end)
  end

  test "bust/2 is scoped by type" do
    s = slug()

    assert :page = Cache.fetch_published("page", s, "en", fn -> :page end)
    assert :post = Cache.fetch_published("post", s, "en", fn -> :post end)

    Cache.bust("page", s)

    assert :page2 = Cache.fetch_published("page", s, "en", fn -> :page2 end)
    # Same slug, different type → untouched.
    assert :post = Cache.fetch_published("post", s, "en", fn -> :ignored end)
  end
end
