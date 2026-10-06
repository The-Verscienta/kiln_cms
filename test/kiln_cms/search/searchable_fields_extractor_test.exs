defmodule KilnCMS.Search.SearchableFieldsExtractorTest do
  @moduledoc """
  #1585 follow-up: a searchable field's value is read as text, not markup —
  HTML is stripped and entities decoded — and a project can read its own
  fields through a `KilnCMS.CMS.SearchableFields.Extractor` (JSON stored as
  text, per-field key allow-lists, field order). Re-indexing and
  re-embedding leave the document's `updated_at` alone.
  """
  # async: false — toggles the global `KilnCMS.Search` and
  # `KilnCMS.CMS.SearchableFields` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.SearchableFields

  doctest KilnCMS.PlainText

  # Decodes JSON text, keeps only the `name` of a `{"language", "name"}`
  # pair, and puts `summary` before everything else.
  defmodule JsonExtractor do
    @behaviour KilnCMS.CMS.SearchableFields.Extractor

    @impl true
    def texts(%{name: "common_names"}, value) when is_binary(value) do
      case Jason.decode(value) do
        {:ok, list} when is_list(list) -> Enum.map(list, &Map.get(&1, "name"))
        _ -> :default
      end
    end

    def texts(%{name: "boom"}, _value), do: raise("extractor bug")
    def texts(_definition, _value), do: :default

    @impl true
    def order(definitions) do
      {first, rest} = Enum.split_with(definitions, &(&1.name == "summary"))
      first ++ rest
    end
  end

  # A broken extractor, every way: throws, exits, and an `order/1` that
  # drops one definition and duplicates another.
  defmodule BadExtractor do
    @behaviour KilnCMS.CMS.SearchableFields.Extractor

    @impl true
    def texts(%{name: "thrower" <> _}, _value), do: throw(:nope)
    def texts(%{name: "exiter"}, _value), do: exit(:nope)
    def texts(_definition, _value), do: :default

    @impl true
    def order([first, _second | rest]), do: [first, first | rest]
    def order(definitions), do: definitions
  end

  defmodule StubEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(text) do
      seed = :erlang.phash2(text)
      {:ok, for(i <- 1..384, do: :math.sin(seed * 1.0e-4 + i))}
    end
  end

  setup do
    search = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    fields = Application.get_env(:kiln_cms, SearchableFields)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Search, search)

      if fields,
        do: Application.put_env(:kiln_cms, SearchableFields, fields),
        else: Application.delete_env(:kiln_cms, SearchableFields)
    end)

    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.put(search, :semantic, false))
    :ok
  end

  defp extractor(module), do: Application.put_env(:kiln_cms, SearchableFields, extractor: module)

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sfx-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "sfx-#{System.unique_integer([:positive])}"

  defp field(admin, name, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, name: name, label: name, field_type: :text}, attrs),
      actor: admin
    )
  end

  defp definition(name, position \\ 0), do: %{name: name, searchable: true, position: position}

  describe "default reading" do
    test "HTML is stripped and entities decoded, in strings nested anywhere" do
      fields = %{
        "uses" => "<p>The rhizome of <em>Coptis chinensis</em> &amp; kin</p>",
        "list" => [%{"effects" => "<p>Clears heat</p>"}]
      }

      assert SearchableFields.texts(fields, [definition("uses"), definition("list", 1)]) ==
               ["The rhizome of Coptis chinensis & kin", "Clears heat"]
    end

    test "malformed markup never raises, and prose with a < is kept" do
      fields = %{"a" => "<p>unclosed <em attr=\"x", "b" => "dose x < 3 g and y > 1"}

      assert SearchableFields.texts(fields, [definition("a"), definition("b", 1)]) ==
               ["unclosed <em attr=\"x", "dose x < 3 g and y > 1"]
    end

    test "a record's stored search_text carries no tags" do
      admin = admin()
      field(admin, "notes", %{searchable: true})

      page =
        CMS.create_page!(
          %{
            title: "Huang Lian",
            slug: slug(),
            custom_fields: %{"notes" => "<p>Intensely <b>bitter</b></p>"}
          },
          actor: admin
        )

      assert page.search_text =~ "Intensely bitter"
      refute page.search_text =~ "<"
    end
  end

  describe "PlainText" do
    test "typographic, Latin-1 and Greek entities decode; unknown ones stay" do
      assert KilnCMS.PlainText.from_html(
               "that&rsquo;s it &mdash; 5&ndash;10&deg;C &plusmn;2 &micro;g &Delta;9 &eacute;t&eacute; &bogus;"
             ) == "that’s it — 5–10°C ±2 µg Δ9 été &bogus;"
    end

    test "inline tags never split a word; block tags do" do
      assert KilnCMS.PlainText.from_html("C<sub>24</sub>H<sub>30</sub>O<sub>3</sub>") ==
               "C24H30O3"

      assert KilnCMS.PlainText.from_html("<p>one</p><p>two</p>") == "one two"
      assert KilnCMS.PlainText.from_html("one<br>two") == "one two"
      assert KilnCMS.PlainText.from_html(~s(see <a href="/x">here</a>.)) == "see here."
    end
  end

  describe "a misbehaving extractor" do
    setup do
      extractor(BadExtractor)
      :ok
    end

    @tag :capture_log
    test "a throw or an exit falls back to the default" do
      fields = %{"thrower" => "<b>kept</b>", "exiter" => "also kept"}

      assert SearchableFields.texts(fields, [definition("thrower"), definition("exiter", 1)]) ==
               ["kept", "also kept"]
    end

    @tag :capture_log
    test "an order that drops or duplicates a field is corrected: every field once" do
      fields = %{"a" => "A", "b" => "B", "c" => "C"}
      defs = [definition("a"), definition("b", 1), definition("c", 2)]

      assert SearchableFields.texts(fields, defs) |> Enum.sort() == ["A", "B", "C"]
    end

    test "a failing field warns once, not once per write" do
      name = "thrower-#{System.unique_integer([:positive])}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..5, do: SearchableFields.texts(%{name => "x"}, [definition(name)])
        end)

      assert length(Regex.scan(~r/BadExtractor failed/, log)) == 1
    end
  end

  describe "an extractor not yet loaded" do
    # `function_exported?/3` is false for a module that has not been loaded,
    # which in interactive mode is every module before its first call. The
    # extractor's `order/1` must still apply on the first write after boot.
    test "its order applies on the very first call" do
      dir = Path.join(System.tmp_dir!(), "sfx-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      module = :"Elixir.KilnCMS.Search.SearchableFieldsExtractorTest.LateLoaded"

      [{^module, beam}] =
        Code.compile_string("""
        defmodule #{inspect(module)} do
          @behaviour KilnCMS.CMS.SearchableFields.Extractor
          def texts(_definition, _value), do: :default
          def order(definitions), do: Enum.reverse(definitions)
        end
        """)

      File.write!(Path.join(dir, "#{module}.beam"), beam)
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
      refute :code.is_loaded(module)
      true = :code.add_patha(String.to_charlist(dir))
      on_exit(fn -> :code.del_path(String.to_charlist(dir)) end)

      extractor(module)
      fields = %{"a" => "A", "b" => "B"}

      assert SearchableFields.texts(fields, [definition("a"), definition("b", 1)]) == ["B", "A"]
    end
  end

  describe "with an extractor" do
    setup do
      extractor(JsonExtractor)
      :ok
    end

    test "it decodes JSON text and keeps only the keys it names" do
      fields = %{
        "common_names" =>
          ~s([{"language":"Chinese","name":"黄连"},{"language":"English","name":"Coptis"}])
      }

      assert SearchableFields.texts(fields, [definition("common_names")]) == ["黄连", "Coptis"]
    end

    test "`:default` leaves a field to the generic rule" do
      assert SearchableFields.texts(%{"x" => "<i>plain</i>"}, [definition("x")]) == ["plain"]
    end

    test "it orders the fields" do
      fields = %{"aaa" => "first by name", "summary" => "the summary"}

      assert SearchableFields.texts(fields, [definition("aaa"), definition("summary")]) ==
               ["the summary", "first by name"]
    end

    @tag :capture_log
    test "a raising extractor falls back to the default and never fails the save" do
      admin = admin()
      field(admin, "boom", %{searchable: true})

      page =
        CMS.create_page!(%{title: "Safe", slug: slug(), custom_fields: %{"boom" => "kaboomword"}},
          actor: admin
        )

      assert page.search_text =~ "kaboomword"
    end

    test "a write indexes the extracted text" do
      admin = admin()
      field(admin, "common_names", %{searchable: true})

      page =
        CMS.create_page!(
          %{
            title: "Huang Lian",
            slug: slug(),
            custom_fields: %{"common_names" => ~s([{"language":"Chinese","name":"黄连"}])}
          },
          actor: admin
        )

      assert page.search_text =~ "黄连"
      refute page.search_text =~ "language"
      refute page.search_text =~ "Chinese"
    end
  end

  describe "re-indexing is not editing" do
    test "flagging a field re-indexes published documents without moving updated_at" do
      admin = admin()
      definition = field(admin, "trade_name")

      page =
        CMS.create_page!(
          %{title: "Widget", slug: slug(), custom_fields: %{"trade_name" => "Frobnicator"}},
          actor: admin
        )
        |> then(&CMS.publish_page!(&1, %{}, actor: admin))

      KilnCMS.DataCase.drain_oban()
      before = CMS.get_page!(page.id, authorize?: false)
      refute before.search_text =~ "Frobnicator"

      CMS.update_field_definition!(definition, %{searchable: true}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      after_sweep = CMS.get_page!(page.id, authorize?: false)
      assert after_sweep.search_text =~ "Frobnicator"
      assert after_sweep.updated_at == before.updated_at
      assert after_sweep.lock_version == before.lock_version
      assert after_sweep.state == :published
    end

    test "storing an embedding leaves updated_at alone" do
      search = Application.get_env(:kiln_cms, KilnCMS.Search, [])

      Application.put_env(
        :kiln_cms,
        KilnCMS.Search,
        Keyword.merge(search, semantic: true, embedder: StubEmbedder)
      )

      admin = admin()
      page = CMS.create_page!(%{title: "Otters", slug: slug()}, actor: admin)
      before = CMS.get_page!(page.id, authorize?: false)
      assert is_nil(before.embedding)

      KilnCMS.DataCase.drain_oban()

      embedded = CMS.get_page!(page.id, authorize?: false)
      assert is_list(embedded.embedding)
      assert %DateTime{} = embedded.embedded_at
      assert embedded.updated_at == before.updated_at
    end

    test "an editorial save still moves updated_at" do
      admin = admin()
      page = CMS.create_page!(%{title: "Edited", slug: slug()}, actor: admin)
      updated = CMS.update_page!(page, %{title: "Edited again"}, actor: admin)
      assert DateTime.compare(updated.updated_at, page.updated_at) == :gt
    end
  end
end
