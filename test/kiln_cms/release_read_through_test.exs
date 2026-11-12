defmodule KilnCMS.ReleaseReadThroughTest do
  @moduledoc """
  `KilnCMS.Release` tasks run under `bin/kiln_cms eval`, where only the repo is
  started, not the content cache: `reserved_paths/0` crashed there on the
  missing Cachex table. `read_through_unless_serving/1` (run by every task's
  `load_app`) turns the cache off for such a VM, so reads go to the database,
  and leaves a serving node's cache alone.

  Not async: it changes the application environment the whole suite reads.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Cache
  alias KilnCMS.Release

  setup do
    original = Application.get_env(:kiln_cms, Cache)

    on_exit(fn ->
      if original,
        do: Application.put_env(:kiln_cms, Cache, original),
        else: Application.delete_env(:kiln_cms, Cache)
    end)
  end

  defp key, do: "release-read-through:#{System.unique_integer([:positive])}"

  test "an eval VM (not serving) reads through, never from the cache" do
    key = key()
    assert Cache.fetch(key, 60_000, fn -> :cached end) == :cached

    assert Release.read_through_unless_serving(false) == :ok

    refute Application.get_env(:kiln_cms, Cache)[:enabled]
    assert Cache.fetch(key, 60_000, fn -> :from_the_database end) == :from_the_database
  end

  test "a serving node (rpc) keeps its cache" do
    key = key()
    assert Cache.fetch(key, 60_000, fn -> :cached end) == :cached

    assert Release.read_through_unless_serving(true) == :ok

    assert Cache.fetch(key, 60_000, fn -> :from_the_database end) == :cached
  end

  test "other cache settings survive" do
    Application.put_env(:kiln_cms, Cache, ttl_hint: 5)

    Release.read_through_unless_serving(false)

    config = Application.get_env(:kiln_cms, Cache)
    assert config[:ttl_hint] == 5
    assert config[:enabled] == false
  end
end
