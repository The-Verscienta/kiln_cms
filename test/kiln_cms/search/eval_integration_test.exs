defmodule KilnCMS.Search.EvalIntegrationTest do
  @moduledoc """
  `mix kiln.search.eval` end to end, in-process: a small published corpus, a
  golden set naming it, the three retrievers, and the report shape the task
  prints. Semantic search is off in the test env, so the ranking under test
  is the keyword leg with the fuzzy fallback — the same one a default install
  evaluates.

  The corpus lives in its own organization so its slugs (the demo seeds'
  `welcome` / `hello-world`, which the shipped example set names) cannot
  collide with any other test's, and so a wrong-tenant read would show up as
  a miss rather than a pass.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Search.Eval
  alias KilnCMS.Search.Eval.Retriever

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "eval-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: "eval",
      slug: "eval-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp rich_text(html), do: %{type: :rich_text, content: html, order: 0}

  defp publish_page(org, actor, attrs) do
    CMS.create_page!(attrs, actor: actor, tenant: org)
    |> then(&CMS.publish_page!(&1, %{}, actor: actor, tenant: org))
  end

  defp publish_post(org, actor, attrs) do
    CMS.create_post!(attrs, actor: actor, tenant: org)
    |> then(&CMS.publish_post!(&1, %{}, actor: actor, tenant: org))
  end

  # The demo seeds' two published records, verbatim (`priv/repo/seeds.exs`),
  # plus the unpublished draft — so the shipped example set is evaluated
  # against the corpus it was written for.
  defp seed_demo_corpus(org, actor) do
    publish_page(org, actor, %{
      title: "Welcome to KilnCMS",
      slug: "welcome",
      seo_title: "Welcome to KilnCMS",
      seo_description: "A world-class, Elixir-native headless CMS.",
      blocks: [
        %{type: :heading, content: "Welcome to KilnCMS", data: %{"level" => 1}, order: 0},
        %{
          type: :rich_text,
          content:
            "<p>This page was created by the seed script and published via the workflow.</p>",
          order: 1
        }
      ]
    })

    CMS.create_page!(
      %{
        title: "About",
        slug: "about",
        blocks: [rich_text("<p>This is an unpublished draft page.</p>")]
      },
      actor: actor,
      tenant: org
    )

    publish_post(org, actor, %{
      title: "Hello, World",
      slug: "hello-world",
      excerpt: "The first post on a KilnCMS-powered site.",
      blocks: [
        %{type: :heading, content: "Hello, World", data: %{"level" => 1}, order: 0},
        %{
          type: :rich_text,
          content:
            "<p>KilnCMS pairs Ash's declarative modeling with LiveView's real-time UX.</p>",
          order: 1
        }
      ]
    })

    KilnCMS.DataCase.drain_oban()
  end

  defp example_rows do
    {:ok, rows} =
      [:code.priv_dir(:kiln_cms), "search_eval", "example.json"]
      |> Path.join()
      |> File.read!()
      |> Eval.parse()

    rows
  end

  defp expected_ranks(report, query) do
    judged = Enum.find(report.queries, &(&1.query == query))
    Map.new(judged.expected, &{&1.slug, &1.rank})
  end

  describe "Retriever.global/2" do
    test "ranks published content only, across sections, with score and legs" do
      org = org()
      actor = admin()
      word = "kilnquartz#{System.unique_integer([:positive])}"

      page = publish_page(org, actor, %{title: "#{word} guide", slug: "g-#{word}", blocks: []})
      post = publish_post(org, actor, %{title: "Notes on #{word}", slug: "n-#{word}", blocks: []})

      _draft =
        CMS.create_page!(%{title: "#{word} draft", slug: "d-#{word}", blocks: []},
          actor: actor,
          tenant: org
        )

      KilnCMS.DataCase.drain_oban()

      row = %{
        query: word,
        expected: [page.slug, post.slug],
        class: "multi_entity",
        type: nil,
        locale: nil
      }

      hits = Retriever.global(row, tenant: org, limit: 10)

      assert Enum.map(hits, & &1.slug) |> Enum.sort() == Enum.sort([page.slug, post.slug])

      for hit <- hits do
        assert is_float(hit.score)
        assert "keyword" in hit.legs
        assert hit.type in ["page", "post"]
        assert hit.section in ["pages", "posts"]
      end

      # One list, best first — the same cross-type order Ask selects in.
      scores = Enum.map(hits, & &1.score)
      assert scores == Enum.sort(scores, :desc)

      # Another org sees none of it.
      assert Retriever.global(row, tenant: org(), limit: 10) == []
    end
  end

  describe "Retriever.ask/2" do
    test "hits are the sources /api/ask would cite, slugs read off their URLs" do
      org = org()
      actor = admin()
      word = "kilnbasalt#{System.unique_integer([:positive])}"
      post = publish_post(org, actor, %{title: "#{word} handbook", slug: "h-#{word}", blocks: []})
      KilnCMS.DataCase.drain_oban()

      row = %{query: word, expected: [post.slug], class: "single_entity", type: nil, locale: nil}
      assert [hit] = Retriever.ask(row, tenant: org, limit: 5)
      assert hit.slug == post.slug
      assert hit.type == "post"
      assert hit.section == "posts"
      assert is_float(hit.score)
      assert "keyword" in hit.legs
    end
  end

  # A stand-in deployment: the shapes `/api/search` and `/api/ask` answer
  # with (`KilnCMSWeb.SearchApiController`, `KilnCMSWeb.AskController`),
  # served over real HTTP so the remote retriever is exercised end to end.
  defmodule StubApi do
    use Plug.Router

    plug :match
    plug :dispatch

    get "/api/search" do
      conn = Plug.Conn.fetch_query_params(conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(search_body(conn.query_params["q"])))
    end

    get "/api/ask" do
      conn = Plug.Conn.fetch_query_params(conn)
      # Deliberately unlabeled: a proxy that drops the content type must not
      # turn a healthy answer into "did not answer with a JSON object".
      send_resp(conn, 200, Jason.encode!(ask_body(conn.query_params["q"])))
    end

    get "/broken/api/search" do
      send_resp(conn, 500, "boom")
    end

    match _ do
      send_resp(conn, 404, "not found")
    end

    defp search_body("huang qi dang shen") do
      %{
        "query" => "huang qi dang shen",
        "results" => %{
          "herbs" => [
            %{
              "id" => "1",
              "type" => "herb",
              "title" => "Da Ding Huang",
              "slug" => "da-ding-huang",
              "path" => "/herbs/da-ding-huang",
              "highlight" => nil,
              "score" => 0.0164,
              "legs" => ["keyword"]
            },
            %{
              "id" => "2",
              "type" => "herb",
              "title" => "Huang Qi",
              "slug" => "huang-qi",
              "path" => "/herbs/huang-qi",
              "highlight" => nil,
              "score" => 0.0246,
              "legs" => ["keyword", "fuzzy"]
            }
          ],
          "concepts" => [
            %{
              "id" => "3",
              "type" => "concept",
              "title" => "Shen",
              "slug" => "shen",
              "path" => "/concepts/shen",
              "highlight" => nil,
              "score" => 0.0161,
              "legs" => ["semantic"]
            }
          ],
          "pages" => [],
          "tags" => [%{"id" => "9", "type" => "tag", "name" => "Qi", "slug" => "qi"}],
          "entries" => []
        },
        "suggestion" => nil
      }
    end

    defp search_body(_junk),
      do: %{"results" => %{"pages" => [], "tags" => []}, "suggestion" => nil}

    defp ask_body(_q) do
      %{
        "question" => "q",
        "answer" => nil,
        "generated" => false,
        "sources" => [
          %{
            "type" => "herb",
            "title" => "Huang Qi",
            "url" => "/en/herbs/huang-qi",
            "excerpt" => "…",
            "score" => 0.0246,
            "legs" => ["keyword"]
          },
          %{
            "type" => "concept",
            "title" => "Shen",
            "url" => "/concepts/shen/",
            "excerpt" => "…",
            "score" => 0.0161,
            "legs" => ["semantic"]
          }
        ]
      }
    end
  end

  describe "Retriever.remote/2" do
    setup do
      server =
        start_supervised!({Bandit, plug: StubApi, scheme: :http, port: 0, startup_log: false})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      %{base_url: "http://127.0.0.1:#{port}"}
    end

    test "reads /api/search's content hits by score, skipping taxonomy hits", %{
      base_url: base_url
    } do
      row = %{
        query: "huang qi dang shen",
        expected: ["huang-qi", "dang-shen"],
        class: "multi_entity",
        type: nil,
        locale: nil
      }

      hits = Retriever.remote(row, base_url: base_url, limit: 10)

      assert Enum.map(hits, & &1.slug) == ["huang-qi", "da-ding-huang", "shen"]
      assert Enum.map(hits, & &1.section) == ["herbs", "herbs", "concepts"]
      assert hd(hits).legs == ["keyword", "fuzzy"]

      judged = Eval.judge(row, hits)
      assert Enum.map(judged.expected, & &1.rank) == [1, nil]

      # A junk query is an empty result set, not an error.
      junk = %{row | query: "asdfghjkl", expected: [], class: "junk"}
      assert Retriever.remote(junk, base_url: base_url) == []
    end

    test "reads /api/ask's sources in order, slugs from their URLs", %{base_url: base_url} do
      row = %{query: "q", expected: ["shen"], class: "single_entity", type: nil, locale: "en"}
      hits = Retriever.remote(row, base_url: base_url, ask: true)

      assert Enum.map(hits, & &1.slug) == ["huang-qi", "shen"]
      assert Enum.map(hits, & &1.type) == ["herb", "concept"]
      assert Eval.reciprocal_rank(Eval.judge(row, hits)) == 0.5
    end

    test "a non-200 raises naming the endpoint rather than scoring as empty", %{
      base_url: base_url
    } do
      row = %{query: "q", expected: [], class: "junk", type: nil, locale: nil}

      assert_raise RuntimeError, ~r{/api/search at #{base_url}/broken answered 500}, fn ->
        Retriever.remote(row, base_url: base_url <> "/broken")
      end
    end
  end

  describe "the report over the demo corpus" do
    test "pins the shipped example set's shape and its keyword-only baseline" do
      org = org()
      seed_demo_corpus(org, admin())

      report =
        Eval.report(example_rows(), &Retriever.global(&1, tenant: org, limit: 10), [1, 3, 5, 10])

      # Every class is present, and every figure is a real average.
      assert report.summary.classes |> Map.keys() |> Enum.sort() == Enum.sort(Eval.classes())
      assert report.summary.overall.queries == length(example_rows())

      # Naming a record finds it, first — and the typed row ranks within pages.
      assert expected_ranks(report, "welcome") == %{"welcome" => 1}
      assert expected_ranks(report, "hello world") == %{"hello-world" => 1}
      assert report.summary.classes["single_entity"].recall[1] == 1.0

      # Body words and question forms ride the keyword leg.
      assert expected_ranks(report, "elixir native headless cms") == %{"welcome" => 1}
      assert expected_ranks(report, "declarative modeling with liveview") == %{"hello-world" => 1}

      assert expected_ranks(report, "what is the first post on this site?") == %{
               "hello-world" => 1
             }

      assert expected_ranks(report, "how was the welcome page published?") == %{"welcome" => 1}

      # Typos reach the fuzzy leg.
      assert %{"welcome" => rank} = expected_ranks(report, "wellcome")
      assert is_integer(rank)
      judged = Enum.find(report.queries, &(&1.query == "wellcome"))
      assert [%{legs: legs}] = judged.expected
      assert "fuzzy" in legs

      # Nonsense returns nothing — the floor #871 guarantees.
      assert report.summary.classes["junk"].recall[1] == 1.0

      # The multi-entity row is the report's D3 and D4 in miniature: AND
      # semantics over "welcome hello world" match neither record, which
      # starves the keyword leg below the fuzzy threshold, and the trigram
      # leg then rescues the one title the query contains verbatim — so one
      # of the two surfaces, by accident, and the eval says exactly that
      # (a fuzzy-only hit, a missing one) rather than hiding it. This is the
      # baseline P2/P4 move.
      assert expected_ranks(report, "welcome hello world") == %{
               "welcome" => nil,
               "hello-world" => 1
             }

      multi = Enum.find(report.queries, &(&1.query == "welcome hello world"))

      assert %{slug: "hello-world", legs: ["fuzzy"]} =
               Enum.find(multi.expected, &(&1.slug == "hello-world"))

      assert report.summary.classes["multi_entity"].recall[10] == 0.5

      # And the draft never scores, whatever the query.
      refute Enum.any?(report.queries, &("about" in &1.returned_slugs))

      # The same report renders and serialises without a database.
      text = Eval.format_text(report, source: "global (in-process)")
      assert text =~ ~r/^single_entity\s+2\s+1\.000\s+1\.000\s+1\.000\s+1\.000\s+1\.000$/m
      assert text =~ ~r/^    welcome\s+#1  keyword/m
      assert text =~ ~s|[junk] "asdfghjkl zzqqxx"  PASS  (0 returned)|

      json =
        report
        |> Eval.to_json_map(source: "global (in-process)")
        |> Jason.encode!()
        |> Jason.decode!()

      assert json["summary"]["classes"]["single_entity"]["recall"]["1"] == 1.0
      assert json["summary"]["classes"]["multi_entity"]["recall"]["10"] == 0.5
    end

    test "the ask path scores the same corpus in its own source order" do
      org = org()
      seed_demo_corpus(org, admin())

      rows = Enum.filter(example_rows(), &(&1.class in ["single_entity", "junk"]))
      report = Eval.report(rows, &Retriever.ask(&1, tenant: org, limit: 6), [1, 3])

      assert report.summary.classes["single_entity"].recall[1] == 1.0
      assert report.summary.classes["junk"].recall[1] == 1.0
      assert report.summary.overall.mrr == 1.0
    end
  end
end
