defmodule KilnCMSWeb.SearchApiBudgetTest do
  @moduledoc """
  `GET /api/search` inside the query budget (#2166): a cut sweep answers in
  time, flagged `partial`, uncacheable, and with a `Server-Timing` header
  that says where the time went.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS

  defmodule SlowEmbedder do
    @behaviour KilnCMS.Search.Embedder

    @impl true
    def embed(_text) do
      KilnCMS.Test.SearchHold.hold(:search_api_budget_delay)
      {:ok, List.duplicate(0.1, 384)}
    end
  end

  defp put_search_env(overrides) do
    base = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.merge(base, overrides))
  end

  defp server_timing(conn) do
    [header] = get_resp_header(conn, "server-timing")

    header
    |> String.split(", ")
    |> Map.new(fn metric ->
      [name, "dur=" <> dur] = String.split(metric, ";")
      {name, String.to_float(dur)}
    end)
  end

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Search, original)
      Application.delete_env(:kiln_cms, :search_api_budget_delay)
    end)

    KilnCMS.Test.SearchHold.release_on_exit()

    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "sab-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    word = "sab#{System.unique_integer([:positive])}"
    page = CMS.create_page!(%{title: "About #{word}", slug: word}, actor: admin)
    page = CMS.publish_page!(page, %{}, actor: admin)

    %{word: word, page: page}
  end

  test "a slow embedding is cut: keyword hits, flagged partial, not cached",
       %{conn: conn, word: word, page: page} do
    # Seconds, not milliseconds: the embedding takes half, and the other half
    # has to carry every section's lexical legs. `/api/search` sweeps every
    # registered content type and has no parameter to narrow that, so an
    # overlay with a dozen more types left 200 ms (at a 400 ms budget) too
    # little on a 2-scheduler CI runner, and the pages section was cut. And a
    # lexical leg still querying at the deadline is killed mid-query, which
    # in the SQL sandbox takes the test's shared connection with it (#2553).
    Application.put_env(:kiln_cms, :search_api_budget_delay, 30_000)
    put_search_env(semantic: true, embedder: SlowEmbedder, query_budget: 3_000)

    {micros, conn} = :timer.tc(fn -> get(conn, "/api/search?q=#{word}") end)
    body = json_response(conn, 200)

    # Nowhere near the embedder's thirty seconds.
    assert micros < 6_000_000
    assert [%{"id" => id}] = body["results"]["pages"]
    assert id == page.id

    assert body["partial"] == true
    assert body["incomplete"]["pages"] == ["semantic", "block", "tag"]
    # Media is not a section of this endpoint, so it is not reported either.
    refute Map.has_key?(body["incomplete"], "media")

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "etag") == []

    timing = server_timing(conn)
    # The embedding gave up at half the budget.
    assert timing["embed"] >= 1_400 and timing["embed"] < 3_000
  end

  test "a finished search is not partial, stays cacheable, and times every part",
       %{conn: conn, word: word} do
    conn = get(conn, "/api/search?q=#{word}&facets=true")
    body = json_response(conn, 200)

    assert body["partial"] == false
    assert body["incomplete"] == %{}
    assert [cache_control] = get_resp_header(conn, "cache-control")
    assert cache_control =~ "public"

    timing = server_timing(conn)

    for name <-
          ~w(embed keyword title alias fuzzy semantic block tag fuse sweep suggest facets total) do
      assert is_float(timing[name]), "no #{name} in Server-Timing"
    end

    assert timing["total"] >= timing["sweep"]
  end

  test "an empty query runs nothing and is not partial", %{conn: conn} do
    body = conn |> get("/api/search?q=") |> json_response(200)

    assert body["partial"] == false
    assert body["incomplete"] == %{}
  end
end
