defmodule KilnCMSWeb.FormEntriesExportControllerTest do
  @moduledoc """
  Form entries CSV export (#477): admin-gated (unlike analytics' editor-gated
  export — `FormSubmission`'s own policy is admin-only), stable columns from
  the form's own field set, and a `?status=` filter matching the moderation UI.
  Keys left behind by a renamed or removed field export under a marked
  header rather than being dropped (#2342).
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "fee-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{
          "email" => email,
          "password" => @password
        },
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp form!(admin) do
    form =
      CMS.create_form!(%{name: "Contact", slug: "fee-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, position: 0},
      actor: admin
    )

    form
  end

  describe "tier gate" do
    test "anonymous requests are forbidden", %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)
      conn = get(conn, ~p"/editor/forms/#{form.id}/entries/export.csv")
      assert conn.status == 403
    end

    test "editors are forbidden (unlike analytics' editor-gated export)", %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)

      conn =
        conn
        |> log_in(authed_user(:editor))
        |> get(~p"/editor/forms/#{form.id}/entries/export.csv")

      assert conn.status == 403
    end

    test "admins may export", %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)

      conn = conn |> log_in(admin) |> get(~p"/editor/forms/#{form.id}/entries/export.csv")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]
    end
  end

  test "an unknown form id 404s rather than exporting the wrong form", %{conn: conn} do
    admin = authed_user(:admin)

    conn =
      conn |> log_in(admin) |> get(~p"/editor/forms/#{Ecto.UUID.generate()}/entries/export.csv")

    assert conn.status == 404
  end

  describe "csv content" do
    test "the header is the form's own field set plus moderation columns, in order", %{
      conn: conn
    } do
      admin = authed_user(:admin)
      form = form!(admin)

      conn = conn |> log_in(admin) |> get(~p"/editor/forms/#{form.id}/entries/export.csv")

      assert conn.resp_body =~ "email,status,spam_score,submitted_at\r\n"
    end

    test "each submission becomes a row with its data, status, and score", %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)

      CMS.create_form_submission!(
        %{form_id: form.id, data: %{"email" => "visitor@example.com"}},
        authorize?: false
      )

      conn = conn |> log_in(admin) |> get(~p"/editor/forms/#{form.id}/entries/export.csv")

      assert conn.resp_body =~ "visitor@example.com,new,0,"
    end

    test "?status=spam exports only spam-flagged submissions", %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)

      kept =
        CMS.create_form_submission!(
          %{form_id: form.id, data: %{"email" => "clean@example.com"}},
          authorize?: false
        )

      spam =
        CMS.create_form_submission!(
          %{form_id: form.id, data: %{"email" => "spammer@example.com"}},
          authorize?: false
        )
        |> CMS.mark_form_submission_spam!(%{}, actor: admin)

      conn =
        conn
        |> log_in(admin)
        |> get(~p"/editor/forms/#{form.id}/entries/export.csv?status=spam")

      refute conn.resp_body =~ "clean@example.com"
      assert conn.resp_body =~ "spammer@example.com"
      assert kept.status == :new
      assert spam.status == :spam
    end

    test "a checkboxes list is joined into one cell; phone and option values keep the formula guard (#2261)",
         %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)

      for {name, type, position} <- [
            {"topics", :checkboxes, 1},
            {"tel", :phone, 2},
            {"amount", :number, 3}
          ] do
        CMS.create_form_field!(
          %{
            form_id: form.id,
            name: name,
            label: name,
            field_type: type,
            position: position,
            options: if(type == :checkboxes, do: ["a", "b", "=SUM(1)"], else: [])
          },
          actor: admin
        )
      end

      CMS.create_form_submission!(
        %{
          form_id: form.id,
          data: %{
            "email" => "v@example.com",
            "topics" => ["a", "=SUM(1)"],
            "tel" => "+1 555 010 0199",
            "amount" => 2.5
          }
        },
        authorize?: false
      )

      conn = conn |> log_in(admin) |> get(~p"/editor/forms/#{form.id}/entries/export.csv")

      assert conn.resp_body =~ "email,topics,tel,amount,status,spam_score,submitted_at\r\n"
      assert conn.resp_body =~ "v@example.com,\"a, =SUM(1)\",'+1 555 010 0199,2.5,new,0,"
    end

    test "a formula-prefixed field value is CSV-injection-guarded", %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)

      CMS.create_form_submission!(
        %{form_id: form.id, data: %{"email" => "=cmd|'/c calc'!A1"}},
        authorize?: false
      )

      conn = conn |> log_in(admin) |> get(~p"/editor/forms/#{form.id}/entries/export.csv")

      assert conn.resp_body =~ "'=cmd"
    end
  end

  describe "renamed and removed fields (#2342)" do
    defp email_field(form, admin) do
      [field] = CMS.form_fields_for!(form.id, actor: admin)
      field
    end

    defp submit!(form, data) do
      CMS.create_form_submission!(%{form_id: form.id, data: data}, authorize?: false)
    end

    defp export(conn, admin, form, query \\ "") do
      conn
      |> log_in(admin)
      |> get("/editor/forms/#{form.id}/entries/export.csv#{query}")
      |> Map.fetch!(:resp_body)
      |> String.split("\r\n", trim: true)
    end

    defp row_with(lines, value), do: Enum.find(lines, &String.contains?(&1, value))

    test "a renamed field's old key gets its own marked column, values kept", %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)

      submit!(form, %{"email" => "before@example.com"})
      CMS.update_form_field!(email_field(form, admin), %{name: "work_email"}, actor: admin)
      submit!(form, %{"work_email" => "after@example.com"})

      [header | rows] = export(conn, admin, form)

      assert header ==
               "work_email,email (renamed or removed),status,spam_score,submitted_at"

      assert row_with(rows, "before@example.com") =~ ~r/^,before@example\.com,new,0,/
      assert row_with(rows, "after@example.com") =~ ~r/^after@example\.com,,new,0,/
    end

    test "a rename chain gives one sorted column per old name", %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)

      submit!(form, %{"email" => "a@example.com"})
      field = CMS.update_form_field!(email_field(form, admin), %{name: "b"}, actor: admin)
      submit!(form, %{"b" => "b@example.com"})
      CMS.update_form_field!(field, %{name: "c"}, actor: admin)

      [header | rows] = export(conn, admin, form)

      assert header ==
               "c,b (renamed or removed),email (renamed or removed),status,spam_score,submitted_at"

      assert row_with(rows, "a@example.com") =~ ~r/^,,a@example\.com,new,/
      assert row_with(rows, "b@example.com") =~ ~r/^,b@example\.com,,new,/
    end

    test "a reused name is the current field's column, not an orphan", %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)

      submit!(form, %{"email" => "old@example.com"})
      CMS.update_form_field!(email_field(form, admin), %{name: "work_email"}, actor: admin)

      CMS.create_form_field!(
        %{form_id: form.id, name: "email", label: "Email", field_type: :email, position: 1},
        actor: admin
      )

      [header | rows] = export(conn, admin, form)

      assert header == "work_email,email,status,spam_score,submitted_at"
      assert row_with(rows, "old@example.com") =~ ~r/^,old@example\.com,new,/
    end

    test "a removed field's values export under the marked header", %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)

      CMS.create_form_field!(
        %{form_id: form.id, name: "phone", label: "Phone", field_type: :string, position: 1},
        actor: admin
      )

      submit!(form, %{"email" => "kept@example.com", "phone" => "555-0100"})

      [phone] =
        form.id |> CMS.form_fields_for!(actor: admin) |> Enum.filter(&(&1.name == "phone"))

      CMS.destroy_form_field!(phone, actor: admin)

      [header | rows] = export(conn, admin, form)

      assert header == "email,phone (renamed or removed),status,spam_score,submitted_at"
      assert row_with(rows, "kept@example.com") =~ ~r/^kept@example\.com,555-0100,new,/
    end

    test "orphan columns come from the exported rows only", %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)

      submit!(form, %{"email" => "clean@example.com"})
      CMS.update_form_field!(email_field(form, admin), %{name: "work_email"}, actor: admin)

      submit!(form, %{"work_email" => "spammer@example.com"})
      |> CMS.mark_form_submission_spam!(%{}, actor: admin)

      [header | rows] = export(conn, admin, form, "?status=spam")

      assert header == "work_email,status,spam_score,submitted_at"
      assert [row] = rows
      assert row =~ ~r/^spammer@example\.com,spam,/
    end

    test "a formula-prefixed value under an old key is still guarded", %{conn: conn} do
      admin = authed_user(:admin)
      form = form!(admin)

      submit!(form, %{"email" => "=cmd|'/c calc'!A1"})
      CMS.update_form_field!(email_field(form, admin), %{name: "work_email"}, actor: admin)

      [_header | [row]] = export(conn, admin, form)

      assert row =~ "'=cmd"
      refute row =~ ~r/(^|,)=cmd/
    end
  end
end
