defmodule KilnCMS.Search.FieldWeightRankingTest do
  @moduledoc """
  #2175 (A3): `search_vector` weights a record's text by role — title and
  name fields `A`, summary fields and the leading words of its searchable
  fields `B`, the rest of those `C`, the body `D` — and the keyword legs rank
  it with `ts_rank_cd`, so a phrase a record states in its own field
  outranks the same words scattered through a long monograph.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Repo
  alias KilnCMS.Search

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.put(original, :semantic, false))
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fw-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "fw-#{System.unique_integer([:positive])}"

  defp field(admin, name, attrs) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, name: name, label: name, field_type: :string}, attrs),
      actor: admin
    )
  end

  # `n` sentences of materia-medica prose with none of the query's words.
  defp filler(n, seed) do
    words =
      ~w(the root is harvested in autumn sliced and dried before use its taste
         lingers and it enters the stomach and the large intestine classical texts
         pair it with other herbs in formulas for the middle burner when the
         pulse is slippery and the tongue coat is thick and yellow)

    Enum.map_join(1..n, " ", fn i ->
      len = 12 + rem(i * 7 + seed, 9)

      sentence =
        Enum.map_join(
          0..(len - 1),
          " ",
          &Enum.at(words, rem(&1 * 5 + i * 3 + seed, length(words)))
        )

      String.capitalize(sentence) <> "."
    end)
  end

  # A long body that carries every word of the phrase a dozen times, never
  # side by side — the shape of a monograph that discusses heat and dampness
  # throughout. Under `ts_rank` over the old title-`A`/text-`B` vector, a
  # body like this outranked the record stating the phrase (0.97 against
  # 0.95): each term's occurrences scored apart, and many of them saturate.
  defp monograph(seed) do
    scattered = [
      "Some say the herb clears the eyes.",
      "Summer heat aggravates the condition.",
      "The sun dries the slices on racks.",
      "Dampness in the soil rots the root."
    ]

    1..12
    |> Enum.flat_map(fn round ->
      Enum.map(scattered, &(filler(1, seed + round) <> " " <> &1))
    end)
    |> Enum.join("\n\n")
  end

  defp page!(admin, attrs) do
    CMS.create_page!(Map.merge(%{slug: slug()}, attrs), actor: admin)
  end

  defp keyword_order(query, admin) do
    :page
    |> Search.hybrid(query, actor: admin, limit: 20)
    |> Enum.filter(&(:keyword in Search.hit_legs(&1)))
    |> Enum.map(& &1.title)
  end

  defp vector(record) do
    %{rows: [[vector]]} =
      Repo.query!("SELECT search_vector::text FROM pages WHERE id = $1", [
        Ecto.UUID.dump!(record.id)
      ])

    vector
  end

  test "a phrase in a record's own field outranks the same words scattered through long monographs" do
    admin = admin()
    field(admin, "actions", %{searchable: true})

    monographs =
      for seed <- 1..4 do
        page!(admin, %{title: "Monograph #{seed}", body_markdown: monograph(seed)})
      end

    own =
      page!(admin, %{
        title: "Huang Lian",
        body_markdown: filler(40, 99),
        custom_fields: %{"actions" => "Clears heat and dries dampness, drains fire."}
      })

    # Every record matches all four words: this is ranking, not matching.
    order = keyword_order("clears heat and dries dampness", admin)
    assert Enum.sort(order) == Enum.sort(["Huang Lian" | Enum.map(monographs, & &1.title)])
    assert hd(order) == own.title

    # Long documents, all of them: the field's phrase wins on weight and
    # adjacency, not on the other records being short.
    assert Enum.all?([own | monographs], &(String.length(&1.search_text) > 3_000))
  end

  test "the words in a record's own field, not as a phrase, outrank the same words through a body" do
    admin = admin()
    field(admin, "actions", %{searchable: true})

    for seed <- 1..2 do
      page!(admin, %{title: "Monograph #{seed}", body_markdown: monograph(seed)})
    end

    page!(admin, %{
      title: "Zhi Zi",
      body_markdown: filler(40, 98),
      custom_fields: %{"actions" => "Dries dampness, drains fire, clears heat."}
    })

    # No record holds the query as a phrase: the role weights decide it —
    # `B` for the field, `D` for the bodies. Over the old vector the field's
    # words were body words like the rest, and the repetitions won.
    assert hd(keyword_order("clears heat and dries dampness", admin)) == "Zhi Zi"
  end

  test "within one field, the words adjacent and in order outrank the same words repeated apart" do
    admin = admin()
    field(admin, "properties", %{searchable: true})

    page!(admin, %{
      title: "Long Dan Cao",
      body_markdown: filler(10, 5),
      custom_fields: %{"properties" => "Intensely bitter and cold."}
    })

    page!(admin, %{
      title: "Ku Shen",
      body_markdown: filler(10, 6),
      custom_fields: %{
        "properties" =>
          "Bitter roots, cold winters, intensely green leaves; a bitter tea " <>
            "for cold hands; the bitter taste stays cold."
      }
    })

    # Both `B`, both short: only the phrase separates them. Cover density
    # alone still favoured the repetitions (0.28 against 0.20).
    assert keyword_order("intensely bitter and cold", admin) == ["Long Dan Cao", "Ku Shen"]
  end

  test "the vector weights the title and name fields A, the fields' lead B and rest C, the body D" do
    admin = admin()
    field(admin, "pinyin", %{names_record: true})
    field(admin, "actions", %{searchable: true, position: 1})
    field(admin, "notes", %{searchable: true, position: 2})

    long_field = Enum.map_join(1..60, " ", fn _ -> "gentle" end) <> " zygomorph"

    record =
      page!(admin, %{
        title: "Gan Cao",
        seo_description: "Harmonizes formulas",
        body_markdown: "Liquorice grows wild.",
        custom_fields: %{
          "pinyin" => "Licorice root",
          "actions" => "Tonifies spleen",
          "notes" => long_field
        }
      })

    assert [a, b, c, d] = record.search_weighted
    assert a == "Gan Cao Licorice root"
    assert b =~ ~r/^Harmonizes formulas Tonifies spleen gentle/
    assert c =~ ~r/zygomorph$/
    assert d =~ "Liquorice grows wild."

    # A name that is not `searchable` is weighted, but stays out of the
    # snippet text.
    refute record.search_text =~ "Licorice"

    vector = vector(record)
    assert vector =~ "'gan':1A"
    assert vector =~ ~r/'licoric':\d+A/
    assert vector =~ ~r/'harmon':\d+B/
    assert vector =~ ~r/'zygomorph':\d+C/
    # `D` is the default weight, which the text form leaves unlabelled.
    assert vector =~ ~r/'liquoric':\d+( |$)/
  end

  test "the label each field definition carries" do
    admin = admin()

    assert [name, plain, hidden] =
             [
               field(admin, "pinyin", %{names_record: true, searchable: true}),
               field(admin, "actions", %{searchable: true}),
               field(admin, "code", %{})
             ]
             |> Enum.map(&Ash.load!(&1, :search_weight, actor: admin))

    assert {name.search_weight, plain.search_weight, hidden.search_weight} == {"A", "B", nil}
  end

  test "a write that moves search_text and not search_weighted falls back to the unweighted vector" do
    admin = admin()
    record = page!(admin, %{title: "Bai Zhu", body_markdown: "Dries dampness."})
    assert vector(record) =~ ~r/'damp':\d+( |$)/

    # What a release that predates `search_weighted` writes, mid-deploy: the
    # buckets would describe the old text, so the trigger clears them.
    Repo.query!(
      "UPDATE pages SET search_text = 'Bai Zhu Strengthens the spleen.' WHERE id = $1",
      [
        Ecto.UUID.dump!(record.id)
      ]
    )

    %{rows: [[weighted]]} =
      Repo.query!("SELECT search_weighted FROM pages WHERE id = $1", [Ecto.UUID.dump!(record.id)])

    assert weighted == nil
    vector = vector(record)
    assert vector =~ ~r/'spleen':\d+B/
    refute vector =~ "damp"

    # The next save through Ash weights it again.
    record = CMS.update_page!(record, %{body_markdown: "Dries dampness again."}, actor: admin)
    assert length(record.search_weighted) == 4
    assert vector(record) =~ ~r/'damp':\d+( |$)/
  end
end
