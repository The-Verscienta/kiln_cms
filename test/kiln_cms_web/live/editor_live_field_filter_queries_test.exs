defmodule KilnCMSWeb.EditorLiveFieldFilterQueriesTest do
  @moduledoc """
  What a custom-field filter and field sort cost the content list: the number
  of queries does not grow with the number of rows it narrows to.
  """
  # async: false — the counter attaches a global telemetry handler, so no other
  # test may run beside it. Sync is not enough on its own (#2504): see
  # `KilnCMS.Test.QueryCounting` for what else keeps the counts this test's own.
  use KilnCMSWeb.ConnCase, async: false
  @moduletag :capture_log

  import KilnCMS.Test.QueryCounting

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

  defp editor_path(query), do: "/editor?" <> URI.encode_query(query)

  defp filtered_queries(conn, prefix) do
    page_queries(
      conn,
      editor_path(%{
        "type" => "page",
        "q" => prefix,
        "cf" => "price:gte:100;note:contains:n",
        "sort" => "-field:price"
      })
    )
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

    assert_same_queries(many_queries, few_queries, "30 rows minus 3 rows")
  end

  defp definition_reads(conn, query) do
    conn
    |> page_queries(editor_path(query))
    |> Enum.count(&(&1.source == "field_definitions"))
  end

  test "a plain single-type list reads the field definitions once, no more than the column strip needs",
       %{conn: conn, admin: admin} do
    org = KilnCMS.Accounts.default_org_id()

    one_read = fn ->
      queries(fn -> CMS.field_definitions_for!(:page, actor: admin, tenant: org) end)
      |> elem(1)
      |> Enum.count(&(&1.source == "field_definitions"))
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
