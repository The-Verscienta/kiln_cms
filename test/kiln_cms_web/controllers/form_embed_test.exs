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
      # `frame-ancestors` is the last directive, so anchoring to the end of the
      # policy is exact — a plain `=~` would still pass if something widened the
      # list, which is the only direction that matters here (#562).
      assert String.ends_with?(policy, "frame-ancestors 'self' https://embedder.test")
      # The site-wide policy would have pinned the bare same-origin form.
      refute String.ends_with?(policy, "frame-ancestors 'self'")
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
      assert String.ends_with?(csp(conn), "frame-ancestors 'self' https://embedder.test")
    end

    test "an inactive form is not embeddable", %{conn: conn} do
      form = form!(active: false)
      conn = conn |> unique_ip() |> get("/forms/#{form.slug}/embed")
      assert html_response(conn, 404) =~ "Form not found"
    end

    # Regression: the 404 text used to be built through a `Gettext.gettext/2`
    # helper taking a runtime variable, so the extractor never saw the msgid, it
    # never entered the catalogs, and the page rendered English in every locale.
    test "the 404 page honours the request locale", %{conn: conn} do
      conn = conn |> unique_ip() |> get("/fr/forms/does-not-exist/embed")

      assert html_response(conn, 404) =~ "Formulaire introuvable."
    after
      Gettext.put_locale(KilnCMSWeb.Gettext, "en")
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
      assert String.ends_with?(csp(conn), "frame-ancestors 'self' https://embedder.test")
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
      assert Embed.parse_env(nil) == []

      assert Embed.parse_env("https://a.test, https://b.test") == [
               "https://a.test",
               "https://b.test"
             ]
    end

    # `nil` in place of a form is the deployment-wide question, asked on purpose
    # — there is no arity that asks it by omission (#648).
    test "frame_ancestors reflects the configured origins" do
      assert Embed.frame_ancestors_for(nil) == "'self' https://embedder.test"
      assert Embed.cross_site?(nil)
      assert Embed.allowed_origins_label(nil) == "https://embedder.test"
    end

    test "frame_ancestors renders each setting" do
      assert Embed.frame_ancestors(:all) == "*"
      assert Embed.frame_ancestors([]) == "'self'"

      # An allowlist EXTENDS same-origin framing rather than replacing it: an
      # operator adding a partner site must not lose their own host.
      assert Embed.frame_ancestors(["https://a.test", "https://b.test"]) ==
               "'self' https://a.test https://b.test"
    end

    # A malformed setting must close the policy, never widen it, and never be
    # applied in part — a half-applied allowlist looks configured but isn't.
    test "frame_ancestors falls back to 'self' for anything unrecognised" do
      assert Embed.frame_ancestors(nil) == "'self'"
      assert Embed.frame_ancestors("https://a.test") == "'self'"
      assert Embed.frame_ancestors([:all]) == "'self'"
      assert Embed.frame_ancestors(["https://a.test", :nope]) == "'self'"
      assert Embed.frame_ancestors([""]) == "'self'"
      assert Embed.frame_ancestors(["   "]) == "'self'"
    end

    # A `*` alone is `:all`; reaching the list branch means it was mixed into an
    # allowlist, where joining it would grant every site while reading as a
    # locked-down config. That is #562 all over again, so it closes instead.
    test "a wildcard mixed into an allowlist closes the policy" do
      assert Embed.frame_ancestors(["*", "https://acme.com"]) == "'self'"
      assert Embed.frame_ancestors(["https://acme.com", "*"]) == "'self'"
    end

    # `frame-ancestors` is the last directive emitted, so an entry carrying a
    # `;` would append directives of the attacker's choosing to the header, and
    # one carrying whitespace would smuggle in extra sources.
    test "frame_ancestors rejects entries that could escape the directive" do
      assert Embed.frame_ancestors(["https://a.test; report-uri https://evil.test"]) == "'self'"
      assert Embed.frame_ancestors(["https://a.test https://evil.test"]) == "'self'"
      assert Embed.frame_ancestors(["https://a.test\nx-frame-options: allow"]) == "'self'"
      assert Embed.frame_ancestors(["'unsafe-inline'"]) == "'self'"
    end

    test "parse_env rejects a value it cannot render safely, keeping the default" do
      # Captured so the stderr warning doesn't clutter the suite output; the
      # point of the warning is that the operator sees it, so assert on it.
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Embed.parse_env("https://a.test,*") == []
          assert Embed.parse_env("https://a.test; report-uri https://evil.test") == []
        end)

      assert warning =~ "EMBED_ORIGINS"
      assert warning =~ "\"*\""
    end

    test "parse_env keeps a well-formed allowlist, wildcards in hosts included" do
      assert Embed.parse_env("https://*.acme.com,https://b.test:8443") == [
               "https://*.acme.com",
               "https://b.test:8443"
             ]
    end

    # EMBED_ORIGINS=* is still how an operator opts back into the old behaviour.
    test "parse_env round-trips the wildcard opt-in" do
      assert "*" |> Embed.parse_env() |> Embed.frame_ancestors() == "*"
    end
  end
end
