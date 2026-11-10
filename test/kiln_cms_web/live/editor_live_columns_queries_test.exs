defmodule KilnCMSWeb.EditorLiveColumnsQueriesTest do
  @moduledoc """
  What the content list's field columns cost: the number of queries does not
  grow with the number of rows (labels are looked up once per page), and the
  select widens for columns and for the in-review badge independently.
  """
  # async: false — the counters attach a global telemetry handler, so no other
  # test may run beside them. Sync is not enough on its own (#2504): see
  # `KilnCMS.Test.QueryCounting` for what else keeps the counts this test's own.
  use KilnCMSWeb.ConnCase, async: false
  @moduletag :capture_log

  import KilnCMS.Test.QueryCounting

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post

  @password "password123456"

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    email = "colq-#{uniq()}@example.com"

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
      target =
        Ash.Seed.seed!(Post, %{title: "T#{n}-#{uniq()}", slug: "t-#{uniq()}", state: :draft})

      person =
        Ash.Seed.seed!(User, %{
          email: "p#{uniq()}@example.com",
          name: "P#{n}",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          role: :editor
        })

      Ash.Seed.seed!(Page, %{
        title: "#{prefix} #{n}",
        slug: "colq-#{uniq()}",
        state: :draft,
        custom_fields: %{
          "related" => %{
            "id" => target.id,
            "type" => "post",
            "slug" => target.slug,
            "title" => target.title
          },
          "owner" => person.id,
          "price" => n
        }
      })
    end
  end

  defp list_queries(conn, prefix), do: page_queries(conn, "/editor?type=page&q=#{prefix}")

  setup %{conn: conn} do
    admin = admin()

    for {name, attrs} <- [
          {"related", %{field_type: :reference, target_type: "post"}},
          {"owner", %{field_type: :user}},
          {"price", %{field_type: :integer}}
        ] do
      CMS.create_field_definition!(
        Map.merge(%{content_type: :page, name: name, label: name}, attrs),
        actor: admin
      )
    end

    {:ok, admin} =
      Accounts.set_content_list_columns(
        admin,
        Accounts.default_org_id(),
        "page",
        ~w(related owner price),
        actor: admin
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    %{conn: conn}
  end

  test "the query count is the same for 3 rows and for 30 with references and people", %{
    conn: conn
  } do
    few = "Few#{uniq()}"
    many = "Many#{uniq()}"
    seed_rows(few, 3)
    seed_rows(many, 30)

    # Warm the one-off caches (registries, settings) so both runs see the same ones.
    list_queries(conn, few)

    many_queries = list_queries(conn, many)
    few_queries = list_queries(conn, few)

    assert_same_queries(many_queries, few_queries, "30 rows minus 3 rows")
  end

  test "the select carries custom_fields for columns and the compliance fields for in_review, together",
       %{conn: conn} do
    prefix = "Sel#{uniq()}"
    seed_rows(prefix, 1)

    page_selects = fn params ->
      for %{source: "pages", sql: sql} <-
            page_queries(conn, "/editor?type=page&q=#{prefix}&#{params}"),
          sql =~ ~r/^SELECT/ and sql =~ "ORDER BY",
          do: sql
    end

    [plain | _] = page_selects.("")
    assert plain =~ "custom_fields"
    refute plain =~ "search_text"

    [both | _] = page_selects.("status=in_review")
    assert both =~ "custom_fields"
    assert both =~ "search_text"
  end
end
