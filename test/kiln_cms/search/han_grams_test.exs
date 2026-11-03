defmodule KilnCMS.Search.HanGramsTest do
  @moduledoc """
  A8: Han text is searchable at the grain Chinese is written in.

  Postgres reads an unbroken run of ideographs as one word, so `吴茱萸` was
  invisible inside `本方以吴茱萸为君药`, and a query that was exactly a
  record's Chinese name ranked it among every formula whose name merely
  began with it. The bigrams (`KilnCMS.Search.HanGrams`) answer the first;
  the title and alias legs' Han exactness answer the second.

  Keyword-only, the real legs against the real database: the formulas below
  are what Verscienta measured (黄连 → Huang Lian at rank 3, 吴茱萸 → Wu Zhu
  Yu at rank 11), at fixture scale.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Repo
  alias KilnCMS.Search
  alias KilnCMS.Search.HanGrams

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.put(original, :semantic, false))
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "han-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "han-#{System.unique_integer([:positive])}"

  defp page(admin, title, body, custom_fields \\ %{}) do
    CMS.create_page!(
      %{title: title, slug: slug(), body_markdown: body, custom_fields: custom_fields},
      actor: admin
    )
  end

  defp titles(results), do: Enum.map(results, & &1.title)

  defp hit(results, record), do: Enum.find(results, &(&1.id == record.id))

  describe "the Han leg" do
    test "finds a word inside an unsegmented run, which the keyword leg cannot" do
      admin = admin()
      formula = page(admin, "Formula notes", "本方以吴茱萸为君药，温中补虚。")

      found = Search.hybrid(:page, "吴茱萸", actor: admin) |> hit(formula)
      assert found, "expected 吴茱萸 to find a run it sits inside"
      assert Search.hit_legs(found) == [:han]

      # A word that is the tail of a run: no prefix match reaches it.
      assert Search.hybrid(:page, "茱萸", actor: admin) |> hit(formula)
    end

    test "matches the bigrams in order, not each character anywhere" do
      admin = admin()
      # Every character of 吴茱萸 is here, but never 吴茱 then 茱萸.
      scattered = page(admin, "Scattered", "茱萸草，吴地所产。")

      refute Search.hybrid(:page, "吴茱萸", actor: admin) |> hit(scattered)
    end

    test "does not run for a query with no Han" do
      admin = admin()
      page(admin, "Kitchen", "A kitchen with 黄连 on the shelf.")

      for hit <- Search.hybrid(:page, "kitchen", actor: admin) do
        refute :han in Search.hit_legs(hit)
      end
    end
  end

  describe "a query that is exactly a record's Chinese name" do
    test "ranks the record whose title's Han text it is first, as :title" do
      admin = admin()

      # The formulas mention 黄连 more often, and their titles hold it too.
      page(admin, "Huang Lian Jie Du Tang 黄连解毒汤", "黄连、黄芩、黄柏、栀子。黄连为君。")
      page(admin, "Huang Lian E Jiao Tang 黄连阿胶汤", "黄连 黄芩 芍药 阿胶。本方以黄连为君药。")
      page(admin, "Ge Gen Qin Lian Tang 葛根黄芩黄连汤", "葛根、黄芩、黄连、甘草")
      herb = page(admin, "Huang Lian 黄连", "Coptis root. Bitter and cold.")

      [first | rest] = Search.hybrid(:page, "黄连", actor: admin)

      assert first.id == herb.id, "got #{inspect(titles([first | rest]))}"
      assert :title in Search.hit_legs(first)
      for other <- rest, do: refute(:title in Search.hit_legs(other))
    end

    test "ranks the record whose flagged name field's Han text it is first, as :alias" do
      admin = admin()

      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "chinese_name",
          label: "Chinese name",
          field_type: :string,
          searchable: true,
          names_record: true
        },
        actor: admin
      )

      # Annotated with its reading, so the query does not contain the whole
      # name and the alias leg's phrase match alone does not name it.
      herb = page(admin, "Wu Zhu Yu", "Evodia fruit.", %{"chinese_name" => "吴茱萸 (wú zhū yú)"})
      page(admin, "Wu Zhu Yu Tang", "吴茱萸 人参 生姜 大枣。本方以吴茱萸为君药。", %{"chinese_name" => "吴茱萸汤"})
      page(admin, "Zuo Jin Wan", "黄连 六份，吴茱萸 一份。", %{"chinese_name" => "左金丸"})
      page(admin, "Wen Jing Tang", "吴茱萸、当归、芍药、川芎、吴茱萸", %{"chinese_name" => "温经汤"})

      [first | rest] = Search.hybrid(:page, "吴茱萸", actor: admin)

      assert first.id == herb.id, "got #{inspect(titles([first | rest]))}"
      assert :alias in Search.hit_legs(first)
      for other <- rest, do: refute(:alias in Search.hit_legs(other))
    end

    test "names nothing whose Han text is longer than the query" do
      admin = admin()
      formula = page(admin, "Huang Lian Jie Du Tang 黄连解毒汤", "")

      found = Search.hybrid(:page, "黄连", actor: admin) |> hit(formula)
      assert found
      refute :title in Search.hit_legs(found)
    end
  end

  describe "the database objects" do
    test "a run becomes its bigrams; a lone character stays a unigram" do
      assert %{rows: [[grams, runs, query, none]]} =
               Repo.query!(
                 "SELECT kiln_han_grams($1), kiln_han_runs($1), kiln_han_tsquery('吴茱萸 黄')::text, kiln_han_tsquery('kitchen') IS NULL",
                 ["黄 is 吴茱萸汤, not 黄连"]
               )

      assert grams == "黄 吴茱 茱萸 萸汤 黄连"
      assert runs == ["黄", "吴茱萸汤", "黄连"]
      assert query == "'吴茱' <-> '茱萸' & '黄':*"
      assert none
    end

    # A3's two vectors (`*_weighted_search_vector_trigger`, #2183), by hand:
    # the role-weighted one from the four `search_weighted` buckets, and the
    # title/`search_text` one for a row without them.
    @role_vector """
    setweight(to_tsvector(kiln_regconfig(locale), coalesce(search_weighted[1], '')), 'A') ||
    setweight(to_tsvector(kiln_regconfig(locale), coalesce(search_weighted[2], '')), 'B') ||
    setweight(to_tsvector(kiln_regconfig(locale), coalesce(search_weighted[3], '')), 'C') ||
    setweight(to_tsvector(kiln_regconfig(locale), coalesce(search_weighted[4], '')), 'D')
    """

    @plain_vector """
    setweight(to_tsvector(kiln_regconfig(locale), coalesce(title, '')), 'A') ||
    setweight(to_tsvector(kiln_regconfig(locale), coalesce(search_text, '')), 'B')
    """

    defp stored(record, select) do
      %{rows: [row]} =
        Repo.query!("SELECT #{select} FROM pages WHERE id = $1", [Ecto.UUID.dump!(record.id)])

      row
    end

    test "the stored vector of a text with no Han is A3's role-weighted vector, exactly" do
      admin = admin()
      plain = page(admin, "Saffron Rice", "Saffron threads bloom in warm stock.")

      assert [4, true] =
               stored(plain, "cardinality(search_weighted), search_vector = #{@role_vector}")
    end

    test "a Han row keeps A3's role weighting and gains its buckets' bigrams at their weights" do
      admin = admin()
      han = page(admin, "Huang Lian 黄连", "本方以吴茱萸为君药。")

      grams = """
      setweight(to_tsvector('pg_catalog.simple', kiln_han_grams(search_weighted[1])), 'A') ||
      setweight(to_tsvector('pg_catalog.simple', kiln_han_grams(search_weighted[2])), 'B') ||
      setweight(to_tsvector('pg_catalog.simple', kiln_han_grams(search_weighted[3])), 'C') ||
      setweight(to_tsvector('pg_catalog.simple', kiln_han_grams(search_weighted[4])), 'D')
      """

      # Exactly A3's vector with the bigrams after it — nothing of A3's moved.
      assert [4, true] =
               stored(
                 han,
                 "cardinality(search_weighted), search_vector = #{@role_vector} || #{grams}"
               )

      # The title's Han name is a bucket-A bigram, the body's a lower one.
      assert [true, true] =
               stored(
                 han,
                 "search_vector @@ to_tsquery('pg_catalog.simple', '黄连:A'), " <>
                   "search_vector @@ to_tsquery('pg_catalog.simple', '茱萸') AND " <>
                   "NOT search_vector @@ to_tsquery('pg_catalog.simple', '茱萸:A')"
               )
    end

    test "a row without buckets keeps A3's title/search_text vector, plus bigrams" do
      admin = admin()
      han = page(admin, "Formula notes", "本方以吴茱萸为君药。")

      # What the previous release writes mid-deploy: search_text moves and the
      # buckets do not, so the trigger clears them (A3's rule).
      Repo.query!("UPDATE pages SET search_text = search_text || ' 吴茱萸汤' WHERE id = $1", [
        Ecto.UUID.dump!(han.id)
      ])

      grams = """
      setweight(to_tsvector('pg_catalog.simple', kiln_han_grams(title)), 'A') ||
      setweight(to_tsvector('pg_catalog.simple', kiln_han_grams(search_text)), 'B')
      """

      assert [nil, true] =
               stored(han, "search_weighted, search_vector = #{@plain_vector} || #{grams}")
    end

    test "the upgrade backfill adds the bigrams to a Han row and leaves another alone" do
      admin = admin()
      han = page(admin, "Formula notes", "本方以吴茱萸为君药。")
      plain = page(admin, "Saffron Rice", "Saffron threads.")

      # Store both the way A3's trigger did before the upgrade.
      for record <- [han, plain] do
        Repo.query!("UPDATE pages SET search_vector = #{@role_vector} WHERE id = $1", [
          Ecto.UUID.dump!(record.id)
        ])
      end

      ctid = fn record ->
        %{rows: [[ctid]]} =
          Repo.query!("SELECT ctid::text FROM pages WHERE id = $1", [Ecto.UUID.dump!(record.id)])

        ctid
      end

      found? = fn -> Search.hybrid(:page, "吴茱萸", actor: admin) |> hit(han) end

      plain_before = ctid.(plain)
      refute found?.()

      Repo.query!(HanGrams.backfill_sql())

      assert found?.()
      assert ctid.(plain) == plain_before, "a row without Han needs no rewrite"
    end
  end

  test "han?/1 agrees with the SQL's character class" do
    assert HanGrams.han?("黄连")
    assert HanGrams.han?("Huang Lian 黄连")
    assert HanGrams.han?("𠀀")
    refute HanGrams.han?("Huang Lian")
    refute HanGrams.han?("ひらがな カタカナ 한국어")
    refute HanGrams.han?(nil)

    for text <- ["黄连", "𠀀", "ひらがな", "한국어", "Huang"] do
      %{rows: [[sql?]]} = Repo.query!("SELECT kiln_han_runs($1) <> '{}'", [text])
      assert sql? == HanGrams.han?(text), text
    end
  end
end
