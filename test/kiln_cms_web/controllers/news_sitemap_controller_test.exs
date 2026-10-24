defmodule KilnCMSWeb.NewsSitemapControllerTest do
  @moduledoc false
  # async: false — served from the shared content cache, like `/sitemap.xml`.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Cache
  alias KilnCMS.CMS
  alias KilnCMS.CMS.{ContentTypes, Post}
  alias KilnCMSWeb.NewsSitemapController

  # Google's news extension schema and the sitemaps protocol schema it plugs
  # into (`<xsd:any namespace="##other" processContents="strict">` in `<url>`),
  # vendored so the test runs offline.
  @xsd_dir "test/support/fixtures/xsd"

  setup do
    Cache.bust_published()

    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "news-sitemap-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    n = System.unique_integer([:positive])

    news =
      CMS.create_type_definition!(
        %{
          name: "story#{n}",
          label: "Story",
          path_segment: "news#{n}",
          schema_org_type: "NewsArticle"
        },
        actor: admin
      )

    %{admin: admin, news: news, n: n}
  end

  defp publish(ctx, slug, title \\ "Story") do
    entry = ContentTypes.create!(ctx.news.name, %{title: title, slug: slug}, actor: ctx.admin)
    CMS.publish_entry!(entry, actor: ctx.admin)
  end

  defp news_sitemap(conn \\ build_conn()), do: conn |> get(~p"/news-sitemap.xml") |> response(200)

  defp url_count(body), do: body |> String.split("<url>") |> length() |> Kernel.-(1)

  test "lists a published NewsArticle with its news: metadata", ctx do
    publish(ctx, "flood-#{ctx.n}", "Flood & storm warning")

    conn = get(build_conn(), ~p"/news-sitemap.xml")
    body = response(conn, 200)

    assert response_content_type(conn, :xml)
    assert body =~ ~s(xmlns:news="http://www.google.com/schemas/sitemap-news/0.9")
    assert body =~ "<loc>http://localhost:4000/news#{ctx.n}/flood-#{ctx.n}</loc>"
    assert body =~ "<news:name>KilnCMS</news:name>"
    assert body =~ "<news:language>en</news:language>"
    assert body =~ "<news:title>Flood &amp; storm warning</news:title>"
    assert body =~ ~r"<news:publication_date>\d{4}-\d{2}-\d{2}T[^<]+</news:publication_date>"
  end

  test "validates against Google's news sitemap schema", ctx do
    publish(ctx, "valid-a-#{ctx.n}", ~s(Quotes "and" <angles>))
    publish(ctx, "valid-b-#{ctx.n}")

    body = news_sitemap()
    assert url_count(body) == 2
    assert :ok = validate(body)
  end

  # The checker is only worth something if it can fail (see the helper below).
  test "the schema check rejects a document Google would", ctx do
    publish(ctx, "checked-#{ctx.n}")
    body = news_sitemap()

    assert {:error, _} =
             validate(String.replace(body, "<news:language>en<", "<news:language>en-GB<"))

    assert {:error, _} = validate(Regex.replace(~r{<news:title>.*?</news:title>}, body, ""))

    assert {:error, _} =
             validate(
               String.replace(body, "<loc>", "<location>")
               |> String.replace("</loc>", "</location>")
             )
  end

  # The sitemaps schema wants at least one `<url>`, so an empty urlset (also what
  # `/sitemap.xml` serves for an empty site) can't pass it; it must still parse,
  # so Google reads "no articles" rather than a broken sitemap.
  test "with nothing recent, the news sitemap is an empty, well-formed urlset" do
    body = news_sitemap()
    assert url_count(body) == 0

    assert {_doc, []} =
             body |> :binary.bin_to_list() |> :xmerl_scan.string(namespace_conformant: true)

    assert body =~ ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9")
  end

  test "excludes items published more than 48 hours ago", ctx do
    publish(ctx, "fresh-#{ctx.n}")

    ctx
    |> publish("stale-#{ctx.n}")
    |> Ash.Seed.update!(%{published_at: DateTime.add(DateTime.utc_now(), -49, :hour)})

    body = news_sitemap()
    assert body =~ "fresh-#{ctx.n}"
    refute body =~ "stale-#{ctx.n}"
  end

  test "drops an unpublished item on the next request", ctx do
    entry = publish(ctx, "retracted-#{ctx.n}")
    assert news_sitemap() =~ "retracted-#{ctx.n}"

    CMS.unpublish_entry!(entry, actor: ctx.admin)

    refute news_sitemap() =~ "retracted-#{ctx.n}"
  end

  test "drafts and audience-gated articles never appear", ctx do
    ContentTypes.create!(ctx.news.name, %{title: "D", slug: "draft-#{ctx.n}"}, actor: ctx.admin)

    ctx
    |> publish("paywalled-#{ctx.n}")
    |> Ash.Seed.update!(%{audience: hd(CMS.Audiences.gated())})

    body = news_sitemap()
    refute body =~ "draft-#{ctx.n}"
    refute body =~ "paywalled-#{ctx.n}"
  end

  test "types that did not declare NewsArticle stay out", ctx do
    Ash.Seed.seed!(Post, %{
      title: "Blog",
      slug: "blog-#{ctx.n}",
      state: :published,
      published_at: DateTime.utc_now()
    })

    refute news_sitemap() =~ "blog-#{ctx.n}"
    assert [%{type: type}] = NewsSitemapController.news_types(KilnCMS.Accounts.default_org_id())
    assert type == ctx.news.name
  end

  test "repeated hits are cached until a publish busts the key", ctx do
    entry = publish(ctx, "cached-#{ctx.n}", "Original title")
    assert news_sitemap() =~ "Original title"

    # Seeded, so no publish hook runs: the cached document must still be served.
    Ash.Seed.update!(entry, %{title: "Renamed quietly"})
    refute news_sitemap() =~ "Renamed quietly"

    # The bust every publish and unpublish already makes drops this key too.
    Cache.bust_sitemap(KilnCMS.Accounts.default_org_id())
    assert news_sitemap() =~ "Renamed quietly"
  end

  describe "robots.txt" do
    test "advertises the news sitemap once a type opts in" do
      body = build_conn() |> get(~p"/robots.txt") |> response(200)
      assert body =~ "Sitemap: http://localhost:4000/sitemap.xml\n"
      assert body =~ "Sitemap: http://localhost:4000/news-sitemap.xml\n"
    end

    test "says nothing about it when no type opted in", ctx do
      CMS.update_type_definition!(ctx.news, %{schema_org_type: "Article"}, actor: ctx.admin)

      body = build_conn() |> get(~p"/robots.txt") |> response(200)
      assert body =~ "Sitemap: http://localhost:4000/sitemap.xml\n"
      refute body =~ "news-sitemap.xml"
    end
  end

  describe "language/1" do
    test "Google wants a bare ISO 639 code, except zh-cn / zh-tw" do
      assert NewsSitemapController.language("en") == "en"
      assert NewsSitemapController.language("pt-BR") == "pt"
      assert NewsSitemapController.language("zh-TW") == "zh-tw"
      assert NewsSitemapController.language("zh_Hant") == "zh-tw"
      assert NewsSitemapController.language("zh") == "zh-cn"
      assert NewsSitemapController.language(nil) == "en"
    end
  end

  # Validates the document against both schemas with OTP's `:xmerl_xsd`, which
  # has two gaps this works around without weakening either schema:
  #
  #   * It names both anonymous members of an `<xsd:union>` alike and rejects
  #     the schema, so the date/dateTime unions (`tLastmod`,
  #     `news:publication_date`) are rewritten to the equivalent
  #     `memberTypes="xsd:date xsd:dateTime"` form.
  #   * It does not resolve the `<xsd:any namespace="##other">` wildcard
  #     through which `<news:news>` enters a `<url>`. So the `<urlset>` is
  #     checked against the sitemaps schema with the extension elements taken
  #     out, and every `<news:news>` against Google's schema as its own root —
  #     which is what the wildcard's `processContents="strict"` asks for.
  defp validate(xml) do
    news = Regex.scan(~r{<news:news>.*?</news:news>}s, xml) |> List.flatten()
    core = Regex.replace(~r{\s*<news:news>.*?</news:news>}s, xml, "")

    [{"sitemap-0.9.xsd", core}]
    |> Enum.concat(Enum.map(news, &{"sitemap-news-0.9.xsd", news_root(&1)}))
    |> Enum.reduce_while(:ok, fn {xsd, doc}, :ok ->
      case validate(doc, xsd) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate(xml, xsd) do
    {:ok, state} = :xmerl_xsd.process_schema(schema_file(xsd))
    {doc, _rest} = xml |> :binary.bin_to_list() |> :xmerl_scan.string(namespace_conformant: true)

    case :xmerl_xsd.validate(doc, state) do
      {:error, reasons} -> {:error, reasons}
      {_valid, _state} -> :ok
    end
  end

  defp news_root(element),
    do:
      String.replace(
        element,
        "<news:news>",
        ~s(<news:news xmlns:news="http://www.google.com/schemas/sitemap-news/0.9">),
        global: false
      )

  @anonymous_date_union ~r{<xsd:union>\s*<xsd:simpleType>\s*<xsd:restriction base="xsd:date"/>\s*</xsd:simpleType>\s*<xsd:simpleType>\s*<xsd:restriction base="xsd:dateTime"/>\s*</xsd:simpleType>\s*</xsd:union>}

  defp schema_file(name) do
    source = File.read!(Path.join(@xsd_dir, name))

    rewritten =
      Regex.replace(
        @anonymous_date_union,
        source,
        ~s(<xsd:union memberTypes="xsd:date xsd:dateTime"/>)
      )

    # The rewrite is the premise of the workaround — if a re-vendored schema
    # stops matching it, say so instead of failing on an xmerl error.
    assert rewritten != source, "#{name} no longer has the date/dateTime union"

    path = Path.join(System.tmp_dir!(), "kiln-#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, rewritten)
    on_exit(fn -> File.rm(path) end)
    String.to_charlist(path)
  end
end
