defmodule KilnCMSWeb.FormEmbedTest do
  @moduledoc """
  Embeddable forms: the iframe document (`GET /forms/:slug/embed`), its
  framing-friendly CSP, and the embed-aware thank-you page.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMSWeb.Embed

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fe-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp form!(opts \\ []) do
    actor = admin()

    form =
      CMS.create_form!(
        %{
          name: "Contact us",
          slug: "fe-#{System.unique_integer([:positive])}",
          success_message: "Merci!",
          active: Keyword.get(opts, :active, true)
        },
        actor: actor
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, required: true},
      actor: actor
    )

    form
  end

  # Every test gets its own IP so rate buckets never cross tests.
  defp unique_ip(conn) do
    Map.put(conn, :remote_ip, {127, 2, rem(System.unique_integer([:positive]), 250), 1})
  end

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  describe "GET /forms/:slug/embed" do
    test "renders a standalone document with the form", %{conn: conn} do
      form = form!()
      conn = conn |> unique_ip() |> get("/forms/#{form.slug}/embed")

      html = html_response(conn, 200)
      assert html =~ "<!DOCTYPE html>"
      assert html =~ "Contact us"
      # Posts back to the normal submit endpoint, marked as an embedded submission.
      assert html =~ ~s(action="/forms/#{form.slug}")
      assert html =~ ~s(name="_kiln_embed")
      # Height reporter is an external script (so CSP needs no nonce).
      assert html =~ "/embed-frame.js"
    end

    test "serves a framing-friendly CSP instead of frame-ancestors 'self'", %{conn: conn} do
      form = form!()
      conn = conn |> unique_ip() |> get("/forms/#{form.slug}/embed")

      policy = csp(conn)
      assert policy =~ "frame-ancestors *"
      refute policy =~ "frame-ancestors 'self'"
      # No inline scripts are needed on the embed page.
      assert policy =~ "script-src 'self'"
    end

    test "is cacheable by shared caches", %{conn: conn} do
      form = form!()
      conn = conn |> unique_ip() |> get("/forms/#{form.slug}/embed")
      assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
    end

    test "an unknown slug 404s but still renders inside the iframe", %{conn: conn} do
      conn = conn |> unique_ip() |> get("/forms/does-not-exist/embed")

      assert html_response(conn, 404) =~ "Form not found"
      # The error page must be framable too, else it renders blank for the embedder.
      assert csp(conn) =~ "frame-ancestors *"
    end

    test "an inactive form is not embeddable", %{conn: conn} do
      form = form!(active: false)
      conn = conn |> unique_ip() |> get("/forms/#{form.slug}/embed")
      assert html_response(conn, 404) =~ "Form not found"
    end
  end

  describe "embedded submission" do
    test "the thank-you page keeps a framing-friendly CSP", %{conn: conn} do
      form = form!()

      conn =
        conn
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"email" => "a@b.com", "_kiln_embed" => "1"})

      html = html_response(conn, 200)
      assert html =~ "Merci!"
      assert csp(conn) =~ "frame-ancestors *"
      # Loads the height reporter so the iframe shrinks to the short message
      # rather than keeping the (much taller) form's height.
      assert html =~ "/embed-frame.js"
    end

    test "a normal on-site submission keeps the strict CSP and no resizer", %{conn: conn} do
      form = form!()

      conn =
        conn
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"email" => "a@b.com"})

      html = html_response(conn, 200)
      assert html =~ "Merci!"
      assert csp(conn) =~ "frame-ancestors 'self'"
      refute html =~ "/embed-frame.js"
    end

    test "the embed marker doesn't leak into the stored submission", %{conn: conn} do
      form = form!()

      conn
      |> unique_ip()
      |> post("/forms/#{form.slug}", %{"email" => "a@b.com", "_kiln_embed" => "1"})

      [submission] = CMS.recent_form_submissions!(form.id, actor: admin())
      refute Map.has_key?(submission.data, "_kiln_embed")
      assert submission.data["email"] == "a@b.com"
    end
  end

  describe "KilnCMSWeb.Embed policy" do
    test "parse_env maps the wildcard, allowlists and blank" do
      assert Embed.parse_env("*") == :all
      assert Embed.parse_env("") == []

      assert Embed.parse_env("https://a.test, https://b.test") == [
               "https://a.test",
               "https://b.test"
             ]
    end

    test "frame_ancestors reflects the configured origins" do
      assert Embed.frame_ancestors() == "*"
    end
  end
end
