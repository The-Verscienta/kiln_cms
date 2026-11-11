defmodule KilnCMSWeb.ContentExportControllerTest do
  @moduledoc """
  The content list as a download (#2293): `GET /editor/content/export.csv|json`.

  Editor-gated; the rows are the list's (same params, same type scope, same
  policies); the columns are the user's saved list columns; limits (rows,
  rate, time) refuse loudly instead of truncating.
  """
  # async: false — the row cap and the time limit are `Application` env
  # (`:content_export`), and the `:export` bucket is lowered through the
  # `RateLimit` env, which is node-wide. Both are put back on exit.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post
  alias KilnCMS.RateLimitHelpers
  alias KilnCMSWeb.ContentExport
  alias KilnCMSWeb.CSV

  @password "password123456"
  @bom <<0xEF, 0xBB, 0xBF>>

  defp uniq, do: System.unique_integer([:positive])

  defp authed_user(role, attrs \\ %{}) do
    email = "export-#{uniq()}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )

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

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp define!(admin, name, attrs) do
    CMS.create_field_definition!(
      Map.merge(
        %{content_type: :page, name: name, label: String.capitalize(name), field_type: :string},
        attrs
      ),
      actor: admin
    )
  end

  defp a_page(prefix, custom_fields \\ %{}, attrs \\ %{}) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{
          title: "#{prefix} page #{uniq()}",
          slug: "exp-#{uniq()}",
          state: :draft,
          custom_fields: custom_fields
        },
        attrs
      )
    )
  end

  defp save_columns(user, names, type \\ "page"),
    do:
      Accounts.set_content_list_columns!(user, Accounts.default_org_id(), type, names,
        actor: user
      )

  defp csv(conn, params), do: get(conn, "/editor/content/export.csv", params)
  defp json_export(conn, params), do: get(conn, "/editor/content/export.json", params)

  # Rows of a CSV body as maps keyed by header.
  defp table(conn) do
    body = response(conn, 200)
    assert String.starts_with?(body, @bom)
    [header | rows] = CSV.parse(body)
    Enum.map(rows, &(header |> Enum.zip(&1) |> Map.new()))
  end

  defp rows_json(conn), do: conn |> response(200) |> Jason.decode!()

  setup %{conn: conn} do
    RateLimitHelpers.restore_limits_on_exit()
    original = Application.get_env(:kiln_cms, :content_export)

    on_exit(fn ->
      if original,
        do: Application.put_env(:kiln_cms, :content_export, original),
        else: Application.delete_env(:kiln_cms, :content_export)
    end)

    admin = authed_user(:admin)
    prefix = "Exp#{uniq()}"

    define!(admin, "price", %{field_type: :integer})
    define!(admin, "flag", %{field_type: :boolean})
    define!(admin, "note", %{field_type: :string})
    define!(admin, "related", %{field_type: :reference, target_type: "post"})
    define!(admin, "owner", %{field_type: :user})
    define!(admin, "photo", %{field_type: :media})
    define!(admin, "secret", %{field_type: :string, private: true})

    %{conn: log_in(conn, admin), admin: admin, prefix: prefix}
  end

  describe "who may download" do
    test "a viewer and an anonymous visitor are refused", %{conn: conn} do
      viewer = authed_user(:viewer)

      for format <- [:csv, :json], c <- [log_in(build_conn(), viewer), build_conn()] do
        conn = get(c, "/editor/content/export.#{format}")
        assert json_response(conn, 403)["error"] == "editor_required"
      end

      assert conn
    end

    test "an editor scoped to posts cannot ask for pages, and gets only posts otherwise", %{
      prefix: prefix
    } do
      scoped = authed_user(:editor, %{editable_types: ["post"]})
      page = a_page(prefix)

      post =
        Ash.Seed.seed!(Post, %{title: "#{prefix} post", slug: "exp-#{uniq()}", state: :draft})

      conn = log_in(build_conn(), scoped)

      assert conn |> csv(%{"type" => "page"}) |> json_response(403)

      rows = conn |> csv(%{"q" => prefix}) |> table()
      assert Enum.map(rows, & &1["id"]) == [post.id]
      refute post.id == page.id
    end

    test "a custom role with narrowed readable types leaks no rows of the types it cannot read",
         %{prefix: prefix} do
      reader = authed_user(:editor, %{editable_types: ["post"], readable_types: ["post"]})
      a_page(prefix)
      conn = log_in(build_conn(), reader)

      assert [] = conn |> csv(%{"q" => prefix}) |> table()
    end
  end

  describe "the file" do
    test "is a UTF-8 BOM, the fixed header and the list's rows, with safe headers", %{
      conn: conn,
      prefix: prefix
    } do
      page = a_page(prefix)
      _other = a_page("Other#{uniq()}")

      conn = csv(conn, %{"type" => "page", "q" => prefix, "status" => "draft"})

      assert [row] = table(conn)

      assert Map.take(row, ~w(id type title slug status locale)) == %{
               "id" => page.id,
               "type" => "page",
               "title" => page.title,
               "slug" => page.slug,
               "status" => "draft",
               "locale" => page.locale
             }

      assert row["updated_at"] =~ ~r/^\d{4}-\d\d-\d\dT/
      assert [ct] = get_resp_header(conn, "content-type")
      assert ct =~ "text/csv"
      assert [cd] = get_resp_header(conn, "content-disposition")
      assert cd =~ ~r/^attachment; filename="content-page-\d{4}-\d\d-\d\d\.csv"$/
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "JSON is an array of objects with the fixed columns and a `fields` object", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      page = a_page(prefix, %{"price" => -5, "flag" => true})
      save_columns(admin, ["price", "flag"])

      conn = json_export(conn, %{"type" => "page", "q" => prefix})

      assert [row] = rows_json(conn)
      assert row["id"] == page.id
      assert row["fields"] == %{"price" => -5, "flag" => true}
      assert [cd] = get_resp_header(conn, "content-disposition")
      assert cd =~ ~r/filename="content-page-[\d-]+\.json"/
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "an empty result is a header only (CSV) or an empty array (JSON)", %{conn: conn} do
      assert [] = conn |> csv(%{"q" => "no-such-#{uniq()}"}) |> table()
      assert [] = conn |> json_export(%{"q" => "no-such-#{uniq()}"}) |> rows_json()
    end

    test "a field named like a fixed column is headed `fields.<name>`", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      define!(admin, "slug", %{field_type: :string})
      a_page(prefix, %{"slug" => "from-field"})
      save_columns(admin, ["slug"])

      assert [row] = conn |> csv(%{"type" => "page", "q" => prefix}) |> table()
      assert row["fields.slug"] == "from-field"
      assert row["slug"] =~ "exp-"
    end
  end

  describe "columns" do
    test "are the saved ones, never the URL's, numbers stay numbers and strings stay guarded",
         %{conn: conn, admin: admin, prefix: prefix} do
      a_page(prefix, %{"price" => -5, "note" => "=1+1"})
      save_columns(admin, ["price", "note"])

      conn = csv(conn, %{"type" => "page", "q" => prefix, "columns" => "flag"})
      [row] = table(conn)

      assert (Map.keys(row) -- ~w(id type title slug status locale updated_at)) |> Enum.sort() ==
               ["note", "price"]

      # `CSV.parse/1` undoes the guard, so look at the raw body for it.
      body = response(conn, 200)
      assert body =~ ",-5,"
      refute body =~ "'-5"
      assert body =~ "'=1+1"
      assert row["price"] == "-5"
      assert row["note"] == "=1+1"
    end

    test "a type=all list on a site with several types has fixed columns only", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      a_page(prefix, %{"price" => 1})
      save_columns(admin, ["price"])

      assert [row] = conn |> csv(%{"q" => prefix}) |> table()
      refute Map.has_key?(row, "price")
    end

    test "references show a readable label; booleans, media and people are typed", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      target =
        Ash.Seed.seed!(Post, %{title: "Target #{uniq()}", slug: "t-#{uniq()}", state: :draft})

      named =
        Ash.Seed.seed!(User, %{
          email: "named-#{uniq()}@example.com",
          name: "Ada Lovelace",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        })

      a_page(prefix, %{
        "related" => %{"id" => target.id, "type" => "post", "slug" => "stale", "title" => "stale"},
        "flag" => false,
        "owner" => named.id,
        "photo" => %{"url" => "/uploads/x/photo.jpg", "alt" => "A photo"}
      })

      save_columns(admin, ["related", "flag", "owner", "photo"])

      # A `:user` field is always private (#2044), so people need the opt-in.
      private = %{"type" => "page", "q" => prefix, "private" => "1"}
      [row] = conn |> csv(private) |> table()

      assert row["related"] == target.title
      assert row["flag"] == "false"
      assert row["owner"] == "Ada Lovelace"
      assert row["photo"] == "photo.jpg"

      body = conn |> json_export(private) |> response(200)
      refute body =~ to_string(named.email)
      refute body =~ "stale"
      assert [%{"fields" => fields}] = Jason.decode!(body)

      assert fields == %{
               "related" => %{"id" => target.id, "label" => target.title},
               "flag" => false,
               "owner" => "Ada Lovelace",
               "photo" => "photo.jpg"
             }
    end

    test "a person without a name shows as such, never as their email", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      email = "nameless-#{uniq()}@example.com"

      nameless =
        Ash.Seed.seed!(User, %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        })

      a_page(prefix, %{"owner" => nameless.id})
      save_columns(admin, ["owner"])

      private = %{"type" => "page", "q" => prefix, "private" => "1"}

      for body <- [
            conn |> csv(private) |> response(200),
            conn |> json_export(private) |> response(200)
          ] do
        refute body =~ email
        assert body =~ "Unnamed user"
      end

      # Without the opt-in the person column is not exported at all.
      refute conn |> csv(%{"type" => "page", "q" => prefix}) |> response(200) =~ "Unnamed user"
    end

    test "an unreadable reference is Unavailable and its title and slug appear nowhere", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      other = KilnCMS.OrgFixtures.org("exp-other")

      secret =
        Ash.Seed.seed!(Post, %{
          title: "SECRET-TITLE-#{uniq()}",
          slug: "secret-#{uniq()}",
          state: :draft,
          org_id: other.id
        })

      a_page(prefix, %{
        "related" => %{
          "id" => secret.id,
          "type" => "post",
          "slug" => secret.slug,
          "title" => secret.title
        }
      })

      save_columns(admin, ["related"])

      csv_body = conn |> csv(%{"type" => "page", "q" => prefix}) |> response(200)
      json_body = conn |> json_export(%{"type" => "page", "q" => prefix}) |> response(200)

      for body <- [csv_body, json_body] do
        assert body =~ "Unavailable"
        refute body =~ secret.title
        refute body =~ secret.slug
        refute body =~ secret.id
      end

      assert [%{"fields" => %{"related" => %{"id" => nil, "label" => "Unavailable"}}}] =
               Jason.decode!(json_body)
    end

    test "private fields are exported only with the opt-in", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      a_page(prefix, %{"secret" => "hush", "price" => 3})
      save_columns(admin, ["secret", "price"])

      params = %{"type" => "page", "q" => prefix}

      assert [row] = conn |> csv(params) |> table()
      refute Map.has_key?(row, "secret")
      assert row["price"] == "3"
      refute conn |> json_export(params) |> response(200) |> String.contains?("hush")

      assert [row] = conn |> csv(Map.put(params, "private", "1")) |> table()
      assert row["secret"] == "hush"
    end

    test "private columns need an editor: the opt-in alone does not widen a custom role's view",
         %{admin: admin, prefix: prefix} do
      a_page(prefix, %{"secret" => "hush"})
      editor = authed_user(:editor)
      save_columns(editor, ["secret"])
      assert admin

      assert [row] =
               log_in(build_conn(), editor)
               |> csv(%{"type" => "page", "q" => prefix, "private" => "1"})
               |> table()

      # An editor sees private fields in the content editor, so this is allowed;
      # without the opt-in the same request has no such column.
      assert row["secret"] == "hush"

      assert [row] =
               log_in(build_conn(), editor) |> csv(%{"type" => "page", "q" => prefix}) |> table()

      refute Map.has_key?(row, "secret")
    end
  end

  describe "scope" do
    test "the list's filters apply: a field filter and a field sort", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      cheap = a_page(prefix, %{"price" => 3})
      mid = a_page(prefix, %{"price" => 30})
      high = a_page(prefix, %{"price" => 300})
      save_columns(admin, ["price"])

      params = %{"type" => "page", "q" => prefix, "cf" => "price:gte:10"}
      ids = fn conn -> conn |> table() |> Enum.map(& &1["id"]) end

      assert conn |> csv(params) |> ids.() |> Enum.sort() == Enum.sort([mid.id, high.id])

      sorted = csv(conn, Map.put(params, "sort", "-field:price"))
      assert ids.(sorted) == [high.id, mid.id]

      ascending = csv(conn, %{"type" => "page", "q" => prefix, "sort" => "field:price"})
      assert ids.(ascending) == [cheap.id, mid.id, high.id]
    end

    test "ids export only those rows, ignore the other filters, and drop foreign ids", %{
      conn: conn,
      prefix: prefix
    } do
      mine = a_page(prefix)
      other_org = KilnCMS.OrgFixtures.org("exp-ids")

      foreign =
        a_page(prefix, %{}, %{org_id: other_org.id})

      _unselected = a_page(prefix)

      params = %{"type" => "page", "ids" => Enum.join([mine.id, foreign.id], ","), "q" => "nope"}
      assert [row] = conn |> csv(params) |> table()
      assert row["id"] == mine.id
    end

    test "ids that are not UUIDs, an empty selection and an oversized one are refused", %{
      conn: conn
    } do
      for ids <- ["not-a-uuid", Ecto.UUID.generate() <> ",x", "", ","] do
        assert conn |> csv(%{"ids" => ids}) |> json_response(400)
      end

      many = Enum.map_join(1..101, ",", fn _ -> Ecto.UUID.generate() end)
      assert %{"error" => "too_many_ids"} = conn |> csv(%{"ids" => many}) |> json_response(400)
      assert conn |> csv(%{"ids" => %{"a" => "b"}}) |> json_response(400)
    end

    test "an unknown type is refused rather than exported as everything", %{conn: conn} do
      assert conn |> csv(%{"type" => "no-such-type"}) |> json_response(403)
    end
  end

  describe "a refusal in the browser" do
    # A link clicked in the list asks for HTML: back to the list with the reason.
    defp browser(conn), do: Plug.Conn.put_req_header(conn, "accept", "text/html")

    test "a bad selection returns to the list without the ids, with a flash", %{conn: conn} do
      conn = conn |> browser() |> csv(%{"type" => "page", "ids" => "nope", "private" => "1"})

      assert redirected_to(conn) == "/editor?type=page"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not a list of content ids"
    end

    test "an unknown type returns to the list without it", %{conn: conn} do
      conn = conn |> browser() |> csv(%{"type" => "no-such-type", "q" => "x"})

      assert redirected_to(conn) == "/editor?q=x"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "cannot export"
    end

    test "over the cap returns to the same filtered list", %{conn: conn, prefix: prefix} do
      Application.put_env(:kiln_cms, :content_export, max_rows: 1)
      for _ <- 1..2, do: a_page(prefix)

      conn = conn |> browser() |> csv(%{"q" => prefix})

      assert redirected_to(conn) == "/editor?q=#{prefix}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "more than 1 rows"
    end

    test "a script that does not ask for HTML still gets JSON", %{conn: conn} do
      assert %{"error" => "invalid_ids"} =
               conn |> csv(%{"ids" => "nope"}) |> json_response(400)
    end
  end

  describe "limits" do
    test "over the row cap is a 413 with a message, never a truncated file", %{
      conn: conn,
      prefix: prefix
    } do
      Application.put_env(:kiln_cms, :content_export, max_rows: 3)
      for _ <- 1..4, do: a_page(prefix)

      assert %{"error" => "too_many_rows", "message" => message} =
               conn |> csv(%{"q" => prefix}) |> json_response(413)

      assert message =~ "3"
      assert conn |> json_export(%{"q" => prefix}) |> json_response(413)

      # At the cap exactly is fine.
      Application.put_env(:kiln_cms, :content_export, max_rows: 4)
      assert length(conn |> csv(%{"q" => prefix}) |> table()) == 4
    end

    test "the cap is per export across types, not per type", %{conn: conn, prefix: prefix} do
      Application.put_env(:kiln_cms, :content_export, max_rows: 3)
      for _ <- 1..2, do: a_page(prefix)

      for n <- 1..2,
          do:
            Ash.Seed.seed!(Post, %{title: "#{prefix} #{n}", slug: "exp-#{uniq()}", state: :draft})

      assert conn |> csv(%{"q" => prefix}) |> json_response(413)
    end

    test "the :export bucket is per actor and answers 429", %{conn: conn, prefix: prefix} do
      RateLimitHelpers.put_limit(:export, 2)
      other = log_in(build_conn(), authed_user(:editor))

      for _ <- 1..2, do: assert(conn |> csv(%{"q" => prefix}) |> response(200))
      assert conn |> csv(%{"q" => prefix}) |> response(429)
      assert [retry] = conn |> csv(%{"q" => prefix}) |> get_resp_header("retry-after")
      assert String.to_integer(retry) >= 1

      # Another account's budget is untouched.
      assert other |> csv(%{"q" => prefix}) |> response(200)
    end

    test "the shipped :export default is ten a minute" do
      assert {10, 60_000} = KilnCMSWeb.RateLimit.default_limits()[:export]
    end

    test "HEAD neither bills the budget nor streams", %{conn: conn, prefix: prefix} do
      RateLimitHelpers.put_limit(:export, 1)

      for _ <- 1..3 do
        conn = head(conn, "/editor/content/export.csv?q=#{prefix}")
        assert response(conn, 200) == ""
      end

      assert conn |> csv(%{"q" => prefix}) |> response(200)
    end

    test "a failure part-way raises instead of ending the download cleanly", %{
      conn: conn,
      prefix: prefix
    } do
      # Past the time limit before the first page: the failure happens after
      # the response has started, which is what must stay visible.
      Application.put_env(:kiln_cms, :content_export, time_limit_ms: -1)
      a_page(prefix)

      for action <- [&csv/2, &json_export/2] do
        assert_raise ContentExport.AbortedError, ~r/time limit/, fn ->
          action.(conn, %{"q" => prefix})
        end
      end
    end

    test "the row cap is enforced again inside the stream", %{prefix: prefix} do
      # Counting passes (below the cap), reading finds more: the stream stops.
      # Drive the stream directly with a plan whose types are read over a cap
      # lowered after the count.
      admin = authed_user(:admin)
      org = Accounts.default_org()
      for _ <- 1..3, do: a_page(prefix)
      Application.put_env(:kiln_cms, :content_export, max_rows: 2)

      plan = %{
        actor: admin,
        org: org,
        types: [KilnCMS.CMS.ContentTypes.get!(:page)],
        filters:
          KilnCMSWeb.EditorLive.Filters.parse(%{"q" => prefix}, %{types: ["page"], locales: []}),
        extra: [],
        columns: [],
        options: []
      }

      assert_raise ContentExport.AbortedError, ~r/row limit/, fn ->
        Enum.to_list(ContentExport.stream(plan))
      end
    end
  end

  describe "pages" do
    test "more rows than one page are all exported, with a query count that does not grow", %{
      conn: conn,
      admin: admin,
      prefix: prefix
    } do
      target = Ash.Seed.seed!(Post, %{title: "T #{uniq()}", slug: "t-#{uniq()}", state: :draft})
      ref = %{"id" => target.id, "type" => "post", "slug" => "s", "title" => "t"}
      for _ <- 1..205, do: a_page(prefix, %{"related" => ref, "price" => 1})
      save_columns(admin, ["related", "price"])

      {count, rows} =
        count_queries(fn -> conn |> csv(%{"type" => "page", "q" => prefix}) |> table() end)

      assert length(rows) == 205
      assert length(Enum.uniq_by(rows, & &1["id"])) == 205
      assert Enum.all?(rows, &(&1["related"] == target.title))

      # Fewer pages: fewer queries; not a query per row.
      {small, _} =
        count_queries(fn ->
          conn |> csv(%{"type" => "page", "q" => prefix, "from" => "2999-01-01"}) |> table()
        end)

      assert count < small + 3 * 12, "#{count} queries for 205 rows vs #{small} for none"
      assert count < 205
    end
  end

  defp count_queries(fun) do
    ref = make_ref()
    me = self()
    id = "export-count-#{inspect(ref)}"

    :telemetry.attach(
      id,
      [:kiln_cms, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == me, do: send(me, {:query, ref})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(id)
    {drain(ref, 0), result}
  end

  defp drain(ref, n) do
    receive do
      {:query, ^ref} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end
end
