defmodule KilnCMS.Search.SemanticCustomSortTest do
  @moduledoc """
  `custom_sort` on the semantic search actions (#2292): order is explicit
  `sort` > `custom_sort` > distance, so a leading custom sort also demotes the
  "a record the query names ranks first" rule (`Content.semantic_sort/1`), the
  same way an explicit `sort` always has. Without `custom_sort` the results
  are exactly what they were.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS

  # A bare name (one word) lands on one axis, anything longer on the other: a
  # short query is nearer every short record than the long one that names it.
  defmodule SoundAlikeEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      hot = if String.contains?(String.trim(text), " "), do: 1, else: 0
      {:ok, for(i <- 0..383, do: if(i == hot, do: 1.0, else: 0.0))}
    end
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      Keyword.merge(original, semantic: true, embedder: SoundAlikeEmbedder)
    )

    KilnCMS.DataCase.exact_vector_scans!()
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "semsort-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "semsort-#{System.unique_integer([:positive])}"

  defp ids(records), do: Enum.map(records, & &1.id)

  # The named record carries the HIGHEST price, so a price sort puts it last
  # while the named-first rule puts it first; decoys are nearer by distance.
  defp seed(admin) do
    price = "price#{System.unique_integer([:positive])}"

    CMS.create_field_definition!(
      %{content_type: :page, name: price, label: "Price", field_type: :integer},
      actor: admin
    )

    mk = fn title, p ->
      CMS.create_page!(%{title: title, slug: slug(), custom_fields: %{price => p}}, actor: admin)
      |> then(&CMS.publish_page!(&1, %{}, actor: admin))
    end

    named = mk.("Shenmen", 90)
    decoys = [mk.("Qimen", 30), mk.("Shenmai", 10), mk.("Jinmen", 20)]
    KilnCMS.DataCase.drain_oban()
    {price, named, decoys}
  end

  for {read, label} <- [
        {:semantic_search_pages!, "base"},
        {:semantic_search_published_pages!, "published"}
      ] do
    test "#{label}: custom_sort orders semantic results; no custom_sort changes nothing" do
      admin = admin()
      {price, named, [qimen, shenmai, jinmen]} = seed(admin)

      # Unchanged default: the named record first, then the rest.
      default = apply(CMS, unquote(read), ["Shenmen", [actor: admin]])
      assert hd(ids(default)) == named.id

      sorted =
        apply(CMS, unquote(read), ["Shenmen", %{custom_sort: price}, [actor: admin]])

      # Custom sort leads: ascending price, the named record (price 90) last.
      assert ids(sorted) == [shenmai.id, jinmen.id, qimen.id, named.id]

      desc =
        apply(CMS, unquote(read), ["Shenmen", %{custom_sort: "-#{price}"}, [actor: admin]])

      assert hd(ids(desc)) == named.id

      # Explicit sort outranks custom_sort.
      explicit =
        apply(CMS, unquote(read), [
          "Shenmen",
          %{custom_sort: price},
          [actor: admin, query: [sort: [title: :asc]]]
        ])

      assert ids(explicit) ==
               ids(Enum.sort_by([named, qimen, shenmai, jinmen], & &1.title))
    end
  end

  test "keyset page 2 continues a custom sort on a semantic action" do
    admin = admin()
    {price, named, [qimen, shenmai, jinmen]} = seed(admin)

    first =
      CMS.semantic_search_pages!("Shenmen", %{custom_sort: price},
        actor: admin,
        page: [limit: 2]
      )

    assert ids(first.results) == [shenmai.id, jinmen.id]
    cursor = List.last(first.results).__metadata__.keyset

    second =
      CMS.semantic_search_pages!("Shenmen", %{custom_sort: price},
        actor: admin,
        page: [limit: 2, after: cursor]
      )

    assert ids(second.results) == [qimen.id, named.id]
  end

  test "custom_sort does not change which rows are returned under a distance floor" do
    admin = admin()
    {price, named, _decoys} = seed(admin)

    # The floor exempts only the rows the query names; the named ids are read
    # without the custom sort, so the same set survives it.
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.put(base, :semantic_max_distance, 0.5))

    plain = "Shenmen" |> CMS.semantic_search_pages!(actor: admin) |> ids() |> Enum.sort()

    sorted =
      "Shenmen"
      |> CMS.semantic_search_pages!(%{custom_sort: price}, actor: admin)
      |> ids()

    assert Enum.sort(sorted) == plain
    assert named.id in sorted
  end
end
