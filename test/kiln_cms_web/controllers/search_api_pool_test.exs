defmodule KilnCMSWeb.SearchApiPoolTest do
  @moduledoc """
  How `GET /api/search` uses the database pool (#1712): one connection per
  request, checked out once, and the analytics write off the request.

  Four connections per search — the old section fan-out — filled a
  10-connection pool with two and a half concurrent searches; the rest of the
  node then queued behind them, and under enough load had its checkouts
  dropped. The unit of both assertions is the process a query runs in,
  observed through the repo's telemetry.
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
  # as `{pid, source, checked_out?}` — `{:write, source}` for an INSERT (the
  # analytics upsert). `checked_out?` is read in the querying
  # process, so it says whether that query ran inside a `Repo.checkout`.
  defp record_queries do
    test = self()
    handler = "sapool-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test or test in Process.get(:"$callers", []) do
          source = if write?(meta[:query]), do: {:write, meta[:source]}, else: meta[:source]
          send(test, {:query, self(), source, KilnCMS.Repo.checked_out?()})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp write?(sql) when is_binary(sql), do: sql =~ ~r/^\s*INSERT/i
  defp write?(_sql), do: false

  defp received_queries(acc \\ []) do
    receive do
      {:query, pid, source, checked_out?} ->
        received_queries([{pid, source, checked_out?} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a search runs every query on one connection, in the request's process", %{conn: conn} do
    word = "sapool#{System.unique_integer([:positive])}"
    published_page("About #{word}")
    record_queries()

    body = conn |> get("/api/search?q=#{word}&facets=true") |> json_response(200)
    assert [_hit] = body["results"]["pages"]

    queries =
      Enum.filter(received_queries(), fn {_pid, source, _} -> source in @search_sources end)

    # Enough of them that "all" means something: a leg per content type,
    # the taxonomy and media sections, the facets.
    assert length(queries) > 10

    # None ran in a task — a task checks out a connection of its own — and
    # every one ran inside the request's single checkout.
    assert Enum.all?(queries, fn {pid, _source, _} -> pid == self() end), inspect(queries)
    assert Enum.all?(queries, fn {_pid, _source, checked_out?} -> checked_out? end)
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
        Enum.filter(received_queries(), fn {_pid, source, _} ->
          source == {:write, "search_queries"}
        end)

      assert writes != []
      assert Enum.all?(writes, fn {pid, _source, _} -> pid != self() end), inspect(writes)
    end
  end

  describe "Search.with_connection/1" do
    test "hands back what the function returns, on one checkout" do
      assert Search.with_connection(fn -> KilnCMS.Repo.checked_out?() end) == true
    end

    test "a pool that dropped the checkout reads as unavailable, not a crash" do
      dropped = fn ->
        raise DBConnection.ConnectionError,
              "connection not available and request was dropped from queue after 500ms"
      end

      assert Search.with_connection(dropped) == {:error, :unavailable}
    end

    test "any other error still raises" do
      assert_raise ArgumentError, "boom", fn ->
        Search.with_connection(fn -> raise ArgumentError, "boom" end)
      end
    end
  end

  defp recorded?(word) do
    KilnCMS.Analytics.top_searches!(authorize?: false, tenant: KilnCMS.Accounts.default_org_id())
    |> Enum.any?(&(&1.query == word))
  end
end
