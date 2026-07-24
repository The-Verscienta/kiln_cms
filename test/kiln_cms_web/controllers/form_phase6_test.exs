defmodule KilnCMSWeb.FormPhase6Test do
  @moduledoc """
  Phase-6 web surface: redirect confirmations (never inside embeds), the JSON
  submission's `redirect` field, and the admin CSV export of submissions.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "f6-#{System.unique_integer([:positive])}@example.com"

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

  defp redirect_form! do
    actor = authed_user(:admin)

    form =
      CMS.create_form!(
        %{
          name: "Redir",
          slug: "f6-redir-#{System.unique_integer([:positive])}",
          success_message: "Thanks!",
          confirmation_type: :redirect,
          redirect_url: "/thank-you"
        },
        actor: actor
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email},
      actor: actor
    )

    form
  end

  test "a redirect confirmation 302s the on-site submission", %{conn: conn} do
    form = redirect_form!()

    conn = post(conn, "/forms/#{form.slug}", %{"email" => "a@b.co"})
    assert redirected_to(conn) == "/thank-you"
  end

  test "an embedded submission shows the message instead of redirecting", %{conn: conn} do
    form = redirect_form!()

    conn = post(conn, "/forms/#{form.slug}", %{"email" => "a@b.co", "_kiln_embed" => "1"})
    assert html_response(conn, 200) =~ "Thanks!"
  end

  test "the JSON submission carries the redirect for the client to perform", %{conn: conn} do
    form = redirect_form!()

    conn = post(conn, "/api/forms/#{form.slug}", %{"email" => "a@b.co"})
    assert %{"ok" => true, "redirect" => "/thank-you"} = json_response(conn, 200)
  end

  test "admins download submissions as CSV; editors are refused", %{conn: conn} do
    admin = authed_user(:admin)

    form =
      CMS.create_form!(
        %{name: "Export", slug: "f6-export-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email},
      actor: admin
    )

    CMS.create_form_field!(
      %{
        form_id: form.id,
        name: "colors",
        label: "Colors",
        field_type: :checkboxes,
        options: ["red", "blue"],
        position: 1
      },
      actor: admin
    )

    CMS.create_form_submission!(
      %{
        form_id: form.id,
        data: %{"email" => "a@b.co", "colors" => ["red", "blue"], "legacy_key" => "=SUM(1)"}
      },
      authorize?: false
    )

    conn2 = conn |> log_in(admin) |> get("/editor/forms/#{form.id}/export.csv")
    assert response_content_type(conn2, :csv) =~ "text/csv"
    body = response(conn2, 200)

    # Header: field columns in form order plus the orphaned data key.
    assert body =~ "submitted_at,locale,email,colors,legacy_key"
    # Lists join; formula-leading values get the injection prefix.
    assert body =~ "a@b.co,red; blue,'=SUM(1)"

    conn3 =
      build_conn() |> log_in(authed_user(:editor)) |> get("/editor/forms/#{form.id}/export.csv")

    assert json_response(conn3, 403)["error"] == "admin_required"
  end
end
