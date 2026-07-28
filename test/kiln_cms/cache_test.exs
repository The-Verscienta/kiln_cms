defmodule KilnCMS.CacheTest do
  @moduledoc false
  # async: false — exercises the shared, app-wide content cache.
  use ExUnit.Case, async: false

  alias KilnCMS.Cache

  setup do
    Cache.bust_published()
    %{org: KilnCMS.Accounts.default_org_id()}
  end

  defp slug, do: "cache-#{System.unique_integer([:positive])}"

  test "caches a computed value and serves it on the next fetch", %{org: org} do
    s = slug()

    assert :first = Cache.fetch_published(org, "page", s, "en", fn -> :first end)
    # The fallback would return :second, but the cached :first wins.
    assert :first = Cache.fetch_published(org, "page", s, "en", fn -> :second end)
  end

  test "does not cache a nil (not-found) result", %{org: org} do
    s = slug()

    assert nil == Cache.fetch_published(org, "page", s, "en", fn -> nil end)
    # Still recomputed, so newly published content shows up immediately.
    assert :now_here = Cache.fetch_published(org, "page", s, "en", fn -> :now_here end)
  end

  test "bust_published clears cached entries", %{org: org} do
    s = slug()

    assert :v1 = Cache.fetch_published(org, "page", s, "en", fn -> :v1 end)
    Cache.bust_published()
    assert :v2 = Cache.fetch_published(org, "page", s, "en", fn -> :v2 end)
  end

  # Audit P-M4: concurrent misses for the same key must compute once, not
  # stampede the DB (Cachex.fetch's Courier deduplicates fallbacks).
  test "concurrent misses for one key run the fallback only once", %{org: org} do
    s = slug()
    counter = :counters.new(1, [:atomics])

    slow_compute = fn ->
      :counters.add(counter, 1, 1)
      Process.sleep(50)
      :computed
    end

    results =
      1..8
      |> Enum.map(fn _ ->
        Task.async(fn -> Cache.fetch_published(org, "page", s, "en", slow_compute) end)
      end)
      |> Task.await_many()

    assert Enum.all?(results, &(&1 == :computed))
    assert :counters.get(counter, 1) == 1
  end

  test "keys are namespaced by type and locale", %{org: org} do
    s = slug()

    assert :page = Cache.fetch_published(org, "page", s, "en", fn -> :page end)
    assert :post = Cache.fetch_published(org, "post", s, "en", fn -> :post end)
    # Same type+slug, different locale → a separate entry.
    assert :fr = Cache.fetch_published(org, "page", s, "fr", fn -> :fr end)
  end

  test "bust/2 drops every locale variant of one record, leaving others intact", %{org: org} do
    s = slug()
    other = slug()

    # Cache the same slug under two locales, plus an unrelated slug.
    assert :en = Cache.fetch_published(org, "page", s, "en", fn -> :en end)
    assert :fr = Cache.fetch_published(org, "page", s, "fr", fn -> :fr end)
    assert :keep = Cache.fetch_published(org, "page", other, "en", fn -> :keep end)

    Cache.bust(org, "page", s)

    # Both locale variants of the busted record are recomputed…
    assert :en2 = Cache.fetch_published(org, "page", s, "en", fn -> :en2 end)
    assert :fr2 = Cache.fetch_published(org, "page", s, "fr", fn -> :fr2 end)
    # …while the unrelated record is still served from cache.
    assert :keep = Cache.fetch_published(org, "page", other, "en", fn -> :ignored end)
  end

  # Regression: the HTML controller caches an enriched payload map while
  # headless delivery caches the bare record for the same {type, slug, locale}.
  # They once shared one key, so whichever endpoint resolved a slug first
  # poisoned the other with a shape it couldn't render (a 500).
  test "record and payload shapes cache independently for the same coordinates", %{org: org} do
    s = slug()

    assert :record = Cache.fetch_published(org, "page", s, "en", fn -> :record end)
    assert :payload = Cache.fetch_published_payload(org, "page", s, "en", fn -> :payload end)

    # Each shape keeps serving its own cached value, never the other's.
    assert :record = Cache.fetch_published(org, "page", s, "en", fn -> :ignored end)
    assert :payload = Cache.fetch_published_payload(org, "page", s, "en", fn -> :ignored end)
  end

  test "bust/3 drops both cached shapes of a record", %{org: org} do
    s = slug()

    assert :record = Cache.fetch_published(org, "page", s, "en", fn -> :record end)
    assert :payload = Cache.fetch_published_payload(org, "page", s, "en", fn -> :payload end)

    Cache.bust(org, "page", s)

    assert :record2 = Cache.fetch_published(org, "page", s, "en", fn -> :record2 end)
    assert :payload2 = Cache.fetch_published_payload(org, "page", s, "en", fn -> :payload2 end)
  end

  test "bust/2 is scoped by type", %{org: org} do
    s = slug()

    assert :page = Cache.fetch_published(org, "page", s, "en", fn -> :page end)
    assert :post = Cache.fetch_published(org, "post", s, "en", fn -> :post end)

    Cache.bust(org, "page", s)

    assert :page2 = Cache.fetch_published(org, "page", s, "en", fn -> :page2 end)
    # Same slug, different type → untouched.
    assert :post = Cache.fetch_published(org, "post", s, "en", fn -> :ignored end)
  end
end
