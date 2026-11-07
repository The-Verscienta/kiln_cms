defmodule KilnCMSWeb.EditorLiveColumnsQueriesTest do
  @moduledoc """
  What the content list's field columns cost: the number of queries does not
  grow with the number of rows (labels are looked up once per page), and the
  select widens for columns and for the in-review badge independently.
  """
  # async: false — the counters below attach a global telemetry handler and
  # count every repo query in the VM, so no other test may run beside them.
  use KilnCMSWeb.ConnCase, async: false
  @moduletag :capture_log

  import Phoenix.LiveViewTest

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

  # Every repo query issued while `fun` runs, as `{source, sql}`.
  defp queries(fun) do
    handler = "colq-#{uniq()}"
    {:ok, agent} = Agent.start_link(fn -> [] end)

    :telemetry.attach(
      handler,
      [:kiln_cms, :repo, :query],
      fn _event, _measure, meta, _config ->
        Agent.update(agent, &[{meta[:source], meta[:query]} | &1])
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    Agent.get(agent, & &1)
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

  defp count_for(conn, prefix) do
    queries(fn ->
      {:ok, lv, _html} = live(conn, "/editor?type=page&q=#{prefix}")
      render(lv)
    end)
    |> length()
  end

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
    count_for(conn, few)

    assert count_for(conn, many) == count_for(conn, few)
  end

  test "the select carries custom_fields for columns and the compliance fields for in_review, together",
       %{conn: conn} do
    prefix = "Sel#{uniq()}"
    seed_rows(prefix, 1)

    page_selects = fn params ->
      for {"pages", sql} <-
            queries(fn ->
              {:ok, lv, _} = live(conn, "/editor?type=page&q=#{prefix}&#{params}")
              render(lv)
            end),
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
