defmodule KilnCMSWeb.FormEntriesExportControllerTest do
  @moduledoc """
  Form entries CSV export (#477): admin-gated (unlike analytics' editor-gated
  export — `FormSubmission`'s own policy is admin-only), stable columns from
  the form's own field set, and a `?status=` filter matching the moderation UI.
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
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

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
end
