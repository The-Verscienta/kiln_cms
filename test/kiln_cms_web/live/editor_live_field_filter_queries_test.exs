defmodule KilnCMSWeb.EditorLiveFieldFilterQueriesTest do
  @moduledoc """
  What a custom-field filter and field sort cost the content list: the number
  of queries does not grow with the number of rows it narrows to.
  """
  # async: false — the counter below attaches a global telemetry handler, so
  # no other test may run beside it.
  #
  # Sync is not enough on its own (#2504: 72 vs 73 on CI). A process an
  # earlier measurement left running still queries — a LiveView's idle-session
  # re-check reads its token row — and a cache bust still in the
  # `KilnCMS.Cache.ClusterBust` mailbox can drop a key the warm-up cached. So
  # the counter keeps only this test's own queries, each LiveView is stopped
  # once measured, and every measurement waits for the busts already sent.
  use KilnCMSWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  @password "password123456"

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    email = "ffq-#{uniq()}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  # The queries made on this test's behalf: by the test process (the static
  # render) or by a process working for it — the LiveView names the test in its
  # `$callers`, and so does anything it starts. Anything else in the VM is not
  # this request's cost.
  defp queries(fun) do
    test = self()
    handler = "ffq-#{uniq()}"
    {:ok, agent} = Agent.start_link(fn -> [] end)

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measure, meta, _config ->
        if test in [self() | Process.get(:"$callers", [])] do
          Agent.update(agent, &[{meta[:source], meta[:query]} | &1])
        end
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, Agent.get(agent, & &1)}
  end

  # One page load's queries. The bust subscriber has handled every bust sent
  # before it starts (a `:sys` call is answered after the messages ahead of it),
  # and its LiveView is gone when it returns: a stopped view cannot query on
  # this test's behalf during the next measurement.
  defp page_queries(conn, query) do
    :sys.get_state(KilnCMS.Cache.ClusterBust)

    {lv, queries} =
      queries(fn ->
        {:ok, lv, _html} = live(conn, "/editor?" <> URI.encode_query(query))
        render(lv)
        lv
      end)

    GenServer.stop(lv.pid)
    queries
  end

  defp by_source(queries), do: Enum.frequencies_by(queries, fn {source, _sql} -> source end)

  # Which tables one list queried more often than the other, so a mismatch
  # names the query that moved rather than only the totals.
  defp source_diff(left, right) do
    {l, r} = {by_source(left), by_source(right)}

    (Map.keys(l) ++ Map.keys(r))
    |> Enum.uniq()
    |> Enum.map(&{&1, Map.get(l, &1, 0) - Map.get(r, &1, 0)})
    |> Enum.reject(fn {_source, delta} -> delta == 0 end)
  end

  defp seed_rows(prefix, count) do
    for n <- 1..count do
      Ash.Seed.seed!(Page, %{
        title: "#{prefix} #{n}",
        slug: "ffq-#{uniq()}",
        state: :draft,
        custom_fields: %{"price" => n + 100, "note" => "n#{n}"}
      })
    end
  end

  defp filtered_queries(conn, prefix) do
    page_queries(conn, %{
      "type" => "page",
      "q" => prefix,
      "cf" => "price:gte:100;note:contains:n",
      "sort" => "-field:price"
    })
  end

  setup %{conn: conn} do
    admin = admin()

    for {name, type} <- [{"price", :integer}, {"note", :string}] do
      CMS.create_field_definition!(
        %{content_type: :page, name: name, label: name, field_type: type},
        actor: admin
      )
    end

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    %{conn: conn, admin: admin}
  end

  test "the query count is the same for 3 matching rows and for 30", %{conn: conn} do
    few = "Few#{uniq()}"
    many = "Many#{uniq()}"
    seed_rows(few, 3)
    seed_rows(many, 30)

    # Warm the one-off caches (registries, settings) so both runs see the same ones.
    filtered_queries(conn, few)

    many_queries = filtered_queries(conn, many)
    few_queries = filtered_queries(conn, few)

    assert length(many_queries) == length(few_queries),
           "query count moved; per table, 30 rows minus 3 rows: " <>
             inspect(source_diff(many_queries, few_queries))

    assert by_source(many_queries) == by_source(few_queries)
  end

  defp definition_reads(conn, query) do
    conn
    |> page_queries(query)
    |> Enum.count(fn {source, _sql} -> source == "field_definitions" end)
  end

  test "a plain single-type list reads the field definitions once, no more than the column strip needs",
       %{conn: conn, admin: admin} do
    org = KilnCMS.Accounts.default_org_id()

    one_read = fn ->
      queries(fn -> CMS.field_definitions_for!(:page, actor: admin, tenant: org) end)
      |> elem(1)
      |> Enum.count(fn {source, _sql} -> source == "field_definitions" end)
    end

    plain = %{"type" => "page", "q" => "nothing#{uniq()}"}
    definition_reads(conn, plain)

    assert one_read.() >= 1
    # `live/2` runs handle_params twice: the static render, then the connected one.
    assert definition_reads(conn, plain) == 2 * one_read.()
    # Asking for a title sort or a status needs no definitions either.
    assert definition_reads(conn, Map.put(plain, "sort", "title")) == 2 * one_read.()
  end
end
