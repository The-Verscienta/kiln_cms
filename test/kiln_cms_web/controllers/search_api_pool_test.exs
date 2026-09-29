defmodule KilnCMSWeb.SearchApiPoolTest do
  @moduledoc """
  How `GET /api/search` uses the database pool (#1712): at most two queries
  in flight per request — so at most two connections — and the analytics
  write off the request.

  Four in flight per search — the old section fan-out — filled a
  10-connection pool with two and a half concurrent searches; the rest of the
  node then queued behind them, and under enough load had its checkouts
  dropped. Observed through the repo's telemetry: which process each query
  ran in, and when it held its connection.
  """
  # async: false — toggles `:async_analytics` and needs the shared sandbox
  # for the supervised analytics task.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Search

  # The tables a search reads. Queries the endpoint's plugs make on the way in
  # (host resolution, rate limiting) happen before the controller and are not
  # the search's; the analytics write has a test of its own.
  @search_sources ~w(pages posts entries categories tags tag_groups media_items)

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sapool-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_page(title) do
    actor = admin()

    %{title: title, slug: "sapool-#{System.unique_integer([:positive])}"}
    |> CMS.create_page!(actor: actor)
    |> then(&CMS.publish_page!(&1, %{}, actor: actor))
  end

  # Every repo query made by this test process or by any process it started,
  # as `{pid, source, held}` — `{:write, source}` for an INSERT (the
  # analytics upsert). `held` is the monotonic interval the query had its
  # connection for: the event fires after decoding, which happens once the
  # connection is back in the pool, and the query itself ran just before.
  defp record_queries do
    test = self()
    handler = "sapool-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, measurements, meta, _config ->
        if self() == test or test in Process.get(:"$callers", []),
          do: send(test, {:query, self(), source(meta), held(measurements)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp source(meta),
    do: if(write?(meta[:query]), do: {:write, meta[:source]}, else: meta[:source])

  defp held(measurements) do
    decoded = System.monotonic_time() - (measurements[:decode_time] || 0)
    {decoded - (measurements[:query_time] || 0), decoded}
  end

  defp write?(sql) when is_binary(sql), do: sql =~ ~r/^\s*INSERT/i
  defp write?(_sql), do: false

  defp received_queries(acc \\ []) do
    receive do
      {:query, pid, source, held} ->
        received_queries([{pid, source, held} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The most intervals that overlap at any one instant.
  defp max_overlap(intervals) do
    intervals
    |> Enum.flat_map(fn {from, to} -> [{from, 1}, {to, -1}] end)
    # At a tie, a release sorts before an acquire: back-to-back is not overlap.
    |> Enum.sort_by(fn {at, delta} -> {at, delta} end)
    |> Enum.scan(0, fn {_at, delta}, open -> open + delta end)
    |> Enum.max(fn -> 0 end)
  end

  # How many of the sweep's worker processes were at work at once: each
  # task's span, from its first query to its last. Not the queries' own
  # intervals — under the test sandbox every process shares one connection,
  # so queries never overlap here whatever the fan-out; the tasks running
  # them do. The request's own process is left out: it waits on the tasks
  # for the whole sweep and queries only before and after it.
  defp max_workers_at_once(queries, caller) do
    queries
    |> Enum.reject(fn {pid, _source, _held} -> pid == caller end)
    |> Enum.group_by(fn {pid, _source, _held} -> pid end, fn {_, _, held} -> held end)
    |> Enum.map(fn {_pid, helds} ->
      {helds |> Enum.map(&elem(&1, 0)) |> Enum.min(),
       helds |> Enum.map(&elem(&1, 1)) |> Enum.max()}
    end)
    |> max_overlap()
  end

  defp search_queries(conn, word) do
    record_queries()
    body = conn |> get("/api/search?q=#{word}&facets=true") |> json_response(200)
    assert [_hit] = body["results"]["pages"]

    queries =
      Enum.filter(received_queries(), fn {_pid, source, _held} -> source in @search_sources end)

    # Enough of them that the bound means something: a leg per content type,
    # the taxonomy sections, the facets.
    assert length(queries) > 10
    queries
  end

  test "a search works at most two sections at once", %{conn: conn} do
    # The ceiling is the default, not a deployment's tuning.
    assert Search.section_concurrency() <= 2

    word = "sapool#{System.unique_integer([:positive])}"
    published_page("About #{word}")
    queries = search_queries(conn, word)

    # It does fan out — the bound is not met by running nothing concurrently…
    assert Enum.any?(queries, fn {pid, _source, _held} -> pid != self() end)
    # …and no more than two sections, so two connections, at a time.
    assert max_workers_at_once(queries, self()) <= 2, inspect(queries)
  end

  test "at a concurrency of 1 every query runs in the request's own process", %{conn: conn} do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.put(original, :section_concurrency, 1))

    word = "sapool#{System.unique_integer([:positive])}"
    published_page("About #{word}")
    queries = search_queries(conn, word)

    # One after another: none in a task, which would hold a connection of
    # its own alongside.
    assert Enum.all?(queries, fn {pid, _source, _held} -> pid == self() end), inspect(queries)
  end

  test "the legs read ids; whole rows are read once, for the hits kept" do
    word = "sapool#{System.unique_integer([:positive])}"
    for i <- 1..3, do: published_page("#{word} guide #{i}")

    test = self()
    handler = "sapool-rows-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test and meta[:source] == "pages", do: send(test, {:sql, meta[:query]})
      end,
      nil
    )

    hits =
      try do
        Search.hybrid(:page, word,
          authorize?: true,
          load: [highlight: %{query: word, locale: "en"}]
        )
      after
        :telemetry.detach(handler)
      end

    assert length(hits) == 3
    # The hits are whole records, as they always were.
    assert Enum.all?(hits, &(is_list(&1.blocks) and is_binary(&1.highlight)))

    sqls = Stream.repeatedly(fn -> receive do: ({:sql, sql} -> sql), after: (0 -> nil) end)
    sqls = Enum.take_while(sqls, & &1)

    # Several legs ran against the table (keyword, title, any-term…); the
    # block trees were read by exactly one statement — the one that read the
    # kept hits.
    assert length(sqls) >= 3
    assert Enum.count(sqls, &(&1 =~ ~s("blocks"))) == 1, Enum.join(sqls, "\n\n")
  end

  test "the endpoint reads no block trees at all: its hits are read with the fields it renders",
       %{conn: conn} do
    word = "sapool#{System.unique_integer([:positive])}"
    published_page("About #{word}")

    test = self()
    handler = "sapool-api-rows-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if (self() == test or test in Process.get(:"$callers", [])) and
             meta[:source] in ~w(pages posts entries),
           do: send(test, {:sql, meta[:query]})
      end,
      nil
    )

    body =
      try do
        conn |> get("/api/search?q=#{word}") |> json_response(200)
      after
        :telemetry.detach(handler)
      end

    assert [%{"title" => "About " <> _, "highlight" => "About <mark>" <> _}] =
             body["results"]["pages"]

    sqls = Stream.repeatedly(fn -> receive do: ({:sql, sql} -> sql), after: (0 -> nil) end)
    sqls = Enum.take_while(sqls, & &1)

    assert sqls != []
    refute Enum.any?(sqls, &(&1 =~ ~s("blocks"))), Enum.join(sqls, "\n\n")
  end

  describe "the analytics write" do
    setup do
      previous = Application.get_env(:kiln_cms, :async_analytics)
      Application.put_env(:kiln_cms, :async_analytics, true)
      on_exit(fn -> Application.put_env(:kiln_cms, :async_analytics, previous) end)
    end

    test "is made off the request, after it has answered", %{conn: conn} do
      word = "sapool#{System.unique_integer([:positive])}"
      published_page("About #{word}")
      record_queries()

      conn |> get("/api/search?q=#{word}") |> json_response(200)

      # The supervised task writes the row; wait for it, so it does not
      # outlive the test's sandbox.
      KilnCMS.Test.Eventually.eventually(fn -> recorded?(word) end,
        message: "the search was never recorded"
      )

      writes =
        Enum.filter(received_queries(), fn {_pid, source, _held} ->
          source == {:write, "search_queries"}
        end)

      assert writes != []
      assert Enum.all?(writes, fn {pid, _source, _held} -> pid != self() end), inspect(writes)
    end
  end

  describe "Search.unless_unavailable/1" do
    test "hands back what the function returns" do
      assert Search.unless_unavailable(fn -> :answered end) == :answered
    end

    test "a pool that dropped the checkout reads as unavailable, not a crash" do
      dropped = fn ->
        raise DBConnection.ConnectionError,
              "connection not available and request was dropped from queue after 500ms"
      end

      assert Search.unless_unavailable(dropped) == {:error, :unavailable}
    end

    test "so does the same error wrapped by Ash, as a read raises it" do
      wrapped = fn ->
        raise Ash.Error.to_error_class(
                DBConnection.ConnectionError.exception(
                  "connection not available and request was dropped from queue after 500ms"
                )
              )
      end

      assert Search.unless_unavailable(wrapped) == {:error, :unavailable}
    end

    test "any other error still raises" do
      assert_raise ArgumentError, "boom", fn ->
        Search.unless_unavailable(fn -> raise ArgumentError, "boom" end)
      end
    end
  end

  defp recorded?(word) do
    KilnCMS.Analytics.top_searches!(authorize?: false, tenant: KilnCMS.Accounts.default_org_id())
    |> Enum.any?(&(&1.query == word))
  end
end
