defmodule KilnCMS.Search.GlobalSectionsTest do
  @moduledoc """
  `global/2` fans its sections out concurrently, bounded by
  `section_concurrency/0`. The fan-out is an implementation detail: the
  returned map must be complete and identical whatever the bound, and a
  failing section must still fail the call rather than quietly vanish from
  the results.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search

  defmodule StubEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gs-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    put_search_env(semantic: true, embedder: StubEmbedder)
    :ok
  end

  test "every section is present, and the result is identical at any concurrency" do
    admin = admin()
    CMS.create_page!(%{title: "alpha guide", slug: "gs-page"}, actor: admin)
    CMS.create_post!(%{title: "alpha notes", slug: "gs-post"}, actor: admin)
    KilnCMS.DataCase.drain_oban()

    expected_keys =
      (Enum.map(KilnCMS.CMS.ContentTypes.all(), & &1.section) ++
         [:entries, :media, :categories, :tags])
      |> Enum.sort()

    ids = fn sections ->
      Map.new(sections, fn {k, records} -> {k, Enum.map(records, & &1.id)} end)
    end

    put_search_env(section_concurrency: 1)
    serial = Search.global("alpha", actor: admin)

    put_search_env(section_concurrency: 8)
    parallel = Search.global("alpha", actor: admin)

    # No section is dropped by the fan-out...
    assert Enum.sort(Map.keys(serial)) == expected_keys
    assert Enum.sort(Map.keys(parallel)) == expected_keys

    # ...and `ordered: false` doesn't change what comes back, since results
    # are keyed by section rather than positional.
    assert ids.(serial) == ids.(parallel)

    # Sanity: the query actually matched something, so this isn't comparing
    # two empty maps.
    assert Enum.any?(serial, fn {_k, records} -> records != [] end)
  end
end
