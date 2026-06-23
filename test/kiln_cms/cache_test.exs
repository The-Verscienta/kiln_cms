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

    assert :first = Cache.fetch_published("page", s, fn -> :first end)
    # The fallback would return :second, but the cached :first wins.
    assert :first = Cache.fetch_published("page", s, fn -> :second end)
  end

  test "does not cache a nil (not-found) result" do
    s = slug()

    assert nil == Cache.fetch_published("page", s, fn -> nil end)
    # Still recomputed, so newly published content shows up immediately.
    assert :now_here = Cache.fetch_published("page", s, fn -> :now_here end)
  end

  test "bust_published clears cached entries" do
    s = slug()

    assert :v1 = Cache.fetch_published("page", s, fn -> :v1 end)
    Cache.bust_published()
    assert :v2 = Cache.fetch_published("page", s, fn -> :v2 end)
  end

  test "keys are namespaced by type" do
    s = slug()

    assert :page = Cache.fetch_published("page", s, fn -> :page end)
    assert :post = Cache.fetch_published("post", s, fn -> :post end)
  end
end
