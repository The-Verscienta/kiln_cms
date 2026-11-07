defmodule KilnCMSWeb.EditorLiveFieldFilterQueriesTest do
  @moduledoc """
  What a custom-field filter and field sort cost the content list: the number
  of queries does not grow with the number of rows it narrows to.
  """
  # async: false — the counter below attaches a global telemetry handler and
  # counts every repo query in the VM, so no other test may run beside it.
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

  defp queries(fun) do
    handler = "ffq-#{uniq()}"
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
      Ash.Seed.seed!(Page, %{
        title: "#{prefix} #{n}",
        slug: "ffq-#{uniq()}",
        state: :draft,
        custom_fields: %{"price" => n + 100, "note" => "n#{n}"}
      })
    end
  end

  defp count_for(conn, prefix) do
    query =
      URI.encode_query(%{
        "type" => "page",
        "q" => prefix,
        "cf" => "price:gte:100;note:contains:n",
        "sort" => "-field:price"
      })

    queries(fn ->
      {:ok, lv, _html} = live(conn, "/editor?" <> query)
      render(lv)
    end)
    |> length()
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
    count_for(conn, few)

    assert count_for(conn, many) == count_for(conn, few)
  end

  defp definition_reads(conn, query) do
    queries(fn ->
      {:ok, lv, _html} = live(conn, "/editor?" <> URI.encode_query(query))
      render(lv)
    end)
    |> Enum.count(fn {source, _sql} -> source == "field_definitions" end)
  end

  test "a plain single-type list reads the field definitions once, no more than the column strip needs",
       %{conn: conn, admin: admin} do
    org = KilnCMS.Accounts.default_org_id()

    one_read = fn ->
      queries(fn -> CMS.field_definitions_for!(:page, actor: admin, tenant: org) end)
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
