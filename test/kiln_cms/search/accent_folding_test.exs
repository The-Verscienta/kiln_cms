defmodule KilnCMS.Search.AccentFoldingTest do
  @moduledoc """
  #1628: diacritics fold out of every full-text leg, on both the indexed and
  the query side, so a name is findable however a reader spells its marks —
  `Zusanli` finds `Zúsānlǐ` and `Zúsānlǐ` finds `Zusanli`.

  The folding lives in the text-search configurations `kiln_regconfig/1`
  returns (`KilnCMS.Search.AccentFolding`), so these run the real legs
  against the real database rather than a hand-written predicate.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Repo
  alias KilnCMS.Search

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    # Keyword-only: the folded legs, with nothing semantic to blur them.
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.put(original, :semantic, false))
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fold-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "fold-#{System.unique_integer([:positive])}"

  defp hit(results, record), do: Enum.find(results, &(&1.id == record.id))

  describe "the keyword and title legs" do
    test "an unaccented query finds an accented title, and the other way round" do
      admin = admin()
      marked = CMS.create_page!(%{title: "Zúsānlǐ", slug: slug()}, actor: admin)
      plain = CMS.create_page!(%{title: "Hegu", slug: slug()}, actor: admin)

      found = Search.hybrid(:page, "Zusanli", actor: admin) |> hit(marked)
      assert found, "expected Zusanli to find Zúsānlǐ"
      assert :keyword in Search.hit_legs(found)
      assert :title in Search.hit_legs(found)

      found = Search.hybrid(:page, "Hégǔ", actor: admin) |> hit(plain)
      assert found, "expected Hégǔ to find Hegu"
      assert :keyword in Search.hit_legs(found)
    end

    test "a body word folds too, and the snippet marks the reader's word" do
      admin = admin()

      page =
        CMS.create_page!(
          %{
            title: "Desserts",
            slug: slug(),
            body_markdown: "Our crème brûlée is torched at the table."
          },
          actor: admin
        )

      [found] =
        Search.hybrid(:page, "creme brulee", actor: admin, load: [highlight: %{query: "creme brulee", locale: "en"}])

      assert found.id == page.id
      assert found.highlight =~ "<mark>crème</mark>"
      assert found.highlight =~ "<mark>brûlée</mark>"
    end

    test "the reader's half-typed last word still matches as a prefix" do
      admin = admin()
      page = CMS.create_page!(%{title: "Jīng Luò", slug: slug()}, actor: admin)

      found = Search.hybrid(:page, "jing lu", actor: admin) |> hit(page)
      assert found
      assert :keyword in Search.hit_legs(found)
    end

    test "Han names are untouched by folding" do
      admin = admin()
      page = CMS.create_page!(%{title: "吴茱萸", slug: slug()}, actor: admin)

      found = Search.hybrid(:page, "吴茱萸", actor: admin) |> hit(page)
      assert found
      assert :keyword in Search.hit_legs(found)
    end
  end

  test "the alias leg folds a flagged name field" do
    admin = admin()

    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: "pinyin_name",
        label: "Pinyin",
        field_type: :string,
        names_record: true
      },
      actor: admin
    )

    point =
      CMS.create_page!(
        %{title: "ST36", slug: slug(), custom_fields: %{"pinyin_name" => "Zúsānlǐ"}},
        actor: admin
      )

    found = Search.hybrid(:page, "where is zusanli", actor: admin) |> hit(point)
    assert found, "expected the alias leg to find the record by its folded pinyin"
    assert :alias in Search.hit_legs(found)
  end

  describe "the database objects" do
    test "kiln_regconfig/1 resolves under an empty search_path, as pg_dump restores" do
      Repo.query!("SET LOCAL search_path = ''")

      assert %{rows: [[config]]} = Repo.query!("SELECT public.kiln_regconfig('fr')::text")
      assert config == "public.kiln_french"

      assert %{rows: [[true]]} =
               Repo.query!(
                 "SELECT to_tsvector(public.kiln_regconfig('en'), 'Zusanli') @@ " <>
                   "phraseto_tsquery(public.kiln_regconfig('en'), 'Zúsānlǐ')"
               )
    end

    test "the upgrade backfill refolds a non-ASCII row and leaves an ASCII one alone" do
      admin = admin()
      marked = CMS.create_page!(%{title: "Qì Xū", slug: slug()}, actor: admin)
      ascii = CMS.create_page!(%{title: "Qi Xu", slug: slug()}, actor: admin)

      # Store both the way the stock configurations did before the upgrade.
      for page <- [marked, ascii] do
        Repo.query!(
          "UPDATE pages SET search_vector = setweight(to_tsvector('english', title), 'A') WHERE id = $1",
          [Ecto.UUID.dump!(page.id)]
        )
      end

      ctid = fn page ->
        %{rows: [[ctid]]} =
          Repo.query!("SELECT ctid::text FROM pages WHERE id = $1", [Ecto.UUID.dump!(page.id)])

        ctid
      end

      # The title leg folds its live expression either way; the keyword leg
      # reads the stored vector, so it is the one the backfill decides.
      keyword_hit? = fn ->
        case Search.hybrid(:page, "qi xu", actor: admin) |> hit(marked) do
          nil -> false
          found -> :keyword in Search.hit_legs(found)
        end
      end

      ascii_before = ctid.(ascii)
      refute keyword_hit?.()

      Repo.query!(KilnCMS.Search.AccentFolding.backfill_sql())

      assert keyword_hit?.()
      assert ctid.(ascii) == ascii_before, "a pure-ASCII row needs no rewrite"
    end
  end
end
