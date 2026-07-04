defmodule KilnCMSWeb.FormControllerTest do
  @moduledoc """
  Public form endpoints: the headless schema (`GET /api/forms/:slug`), the
  on-site submission (`POST /forms/:slug`, thank-you page), the JSON
  submission (`POST /api/forms/:slug`), honeypot fake-success, and the
  per-IP rate limit.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fc-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp form! do
    actor = admin()

    form =
      CMS.create_form!(
        %{
          name: "Contact",
          slug: "fc-#{System.unique_integer([:positive])}",
          success_message: "Merci!"
        },
        actor: actor
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, required: true},
      actor: actor
    )

    CMS.create_form_field!(
      %{form_id: form.id, name: "message", label: "Message", field_type: :text},
      actor: actor
    )

    form
  end

  # Every test gets its own IP so the tight :form bucket never crosses tests.
  defp unique_ip(conn) do
    Map.put(conn, :remote_ip, {127, 1, rem(System.unique_integer([:positive]), 250), 1})
  end

  test "GET /api/forms/:slug returns the schema", %{conn: conn} do
    form = form!()

    body = conn |> get("/api/forms/#{form.slug}") |> json_response(200)

    assert body["slug"] == form.slug
    assert body["honeypot_field"] == "website"
    assert body["submit_url"] == "/forms/#{form.slug}"

    assert [%{"name" => "email", "type" => "email", "required" => true}, %{"name" => "message"}] =
             body["fields"]
  end

  test "GET /api/forms/:slug 404s for unknown or inactive forms", %{conn: conn} do
    form = form!()
    CMS.update_form!(form, %{active: false}, authorize?: false)

    assert conn |> get("/api/forms/#{form.slug}") |> json_response(404)
    assert conn |> get("/api/forms/nope") |> json_response(404)
  end

  test "POST /forms/:slug stores the submission and renders the success message", %{conn: conn} do
    form = form!()

    html =
      conn
      |> unique_ip()
      |> post("/forms/#{form.slug}", %{"email" => "a@b.co", "message" => "hi"})
      |> html_response(200)

    assert html =~ "Merci!"

    assert [submission] = CMS.recent_form_submissions!(form.id, authorize?: false)
    assert submission.data == %{"email" => "a@b.co", "message" => "hi"}
  end

  test "invalid submissions render errors with a 422", %{conn: conn} do
    form = form!()

    html =
      conn
      |> unique_ip()
      |> post("/forms/#{form.slug}", %{"email" => "not-an-email"})
      |> html_response(422)

    assert html =~ "email"
    assert CMS.recent_form_submissions!(form.id, authorize?: false) == []
  end

  test "the honeypot gets a fake success and stores nothing", %{conn: conn} do
    form = form!()

    html =
      conn
      |> unique_ip()
      |> post("/forms/#{form.slug}", %{
        "email" => "a@b.co",
        "website" => "http://spam.example"
      })
      |> html_response(200)

    assert html =~ "Merci!"
    assert CMS.recent_form_submissions!(form.id, authorize?: false) == []
  end

  test "POST /api/forms/:slug accepts JSON and returns field errors", %{conn: conn} do
    form = form!()

    ok =
      conn
      |> unique_ip()
      |> put_req_header("content-type", "application/json")
      |> post("/api/forms/#{form.slug}", Jason.encode!(%{email: "a@b.co"}))
      |> json_response(200)

    assert ok["ok"] == true
    assert ok["message"] == "Merci!"

    bad =
      build_conn()
      |> unique_ip()
      |> put_req_header("content-type", "application/json")
      |> post("/api/forms/#{form.slug}", Jason.encode!(%{email: "nope"}))
      |> json_response(422)

    assert bad["ok"] == false
    assert bad["errors"]["email"]
  end

  test "submissions are rate limited per IP" do
    form = form!()
    ip = {127, 2, rem(System.unique_integer([:positive]), 250), 1}

    for _ <- 1..20 do
      build_conn()
      |> Map.put(:remote_ip, ip)
      |> post("/forms/#{form.slug}", %{"email" => "a@b.co"})
    end

    denied =
      build_conn()
      |> Map.put(:remote_ip, ip)
      |> post("/forms/#{form.slug}", %{"email" => "a@b.co"})

    assert denied.status == 429
    assert get_resp_header(denied, "retry-after") != []
  end
end
