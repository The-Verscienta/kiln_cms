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

    # Taxonomy keys come from the registry rather than a literal list (#530) —
    # the literal is how `tag_groups` came to be missing from search in the
    # first place, and restating it here would let it happen again.
    expected_keys =
      (Enum.map(KilnCMS.CMS.ContentTypes.all(), & &1.section) ++
         [:entries, :media] ++
         Enum.map(KilnCMS.CMS.Taxonomy.searchable(), &elem(&1, 0)))
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

  describe ":sections (#960)" do
    test "only the requested sections run, and the rest are absent" do
      admin = admin()
      CMS.create_page!(%{title: "alpha guide", slug: "gs-sel-page"}, actor: admin)
      CMS.create_post!(%{title: "alpha notes", slug: "gs-sel-post"}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      result = Search.global("alpha", actor: admin, sections: [:pages, :posts])

      assert Enum.sort(Map.keys(result)) == [:pages, :posts]

      # Absent, not empty: "you did not ask" and "there were no matches" are
      # different answers, and conflating them is how a caller ends up
      # believing a section is empty when it never ran.
      refute Map.has_key?(result, :media)
      refute Map.has_key?(result, :tags)

      # …and the sections asked for still actually searched.
      assert Enum.any?(result.pages, &(&1.slug == "gs-sel-page"))
    end

    test "the default is still every section" do
      admin = admin()
      all = Search.global("alpha", actor: admin)

      assert Map.has_key?(all, :media)
      assert Map.has_key?(all, :tags)
      assert Map.has_key?(all, :entries)
    end

    test "content_sections/0 is derived from the registry, not a literal" do
      # The point of exporting it: a caller that says "the content sections"
      # keeps meaning that when a type is registered. A literal list is how
      # `tag_groups` came to be missing from search entirely (#530).
      expected = Enum.map(KilnCMS.CMS.ContentTypes.all(), & &1.section) ++ [:entries]

      assert Enum.sort(Search.content_sections()) == Enum.sort(expected)
      assert :entries in Search.content_sections()

      # It is a valid selection — a section key it named that global/2 did not
      # know would raise below.
      result = Search.global("alpha", actor: admin(), sections: Search.content_sections())
      assert Enum.sort(Map.keys(result)) == Enum.sort(Search.content_sections())
    end

    test "an unknown section raises rather than silently returning less" do
      # Ignoring it would answer a sweep missing a section the caller asked
      # for, with nothing failing — which is exactly how #530 happened.
      assert_raise ArgumentError, ~r/unknown search section/, fn ->
        Search.global("alpha", actor: admin(), sections: [:pages, :pagez])
      end
    end

    test "the raise names what is registered" do
      # On an install with plugin-registered types the valid set is not
      # something the caller can read off the source, so the message has to
      # carry it.
      error =
        assert_raise ArgumentError, fn ->
          Search.global("alpha", actor: admin(), sections: [:nope])
        end

      assert error.message =~ ":nope"
      assert error.message =~ "registered sections are"
      assert error.message =~ ":media"
    end
  end
end
