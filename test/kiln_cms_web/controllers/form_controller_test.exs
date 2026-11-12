defmodule KilnCMSWeb.FormControllerTest do
  @moduledoc """
  Public form endpoints: the headless schema (`GET /api/forms/:slug`), the
  on-site submission (`POST /forms/:slug`, thank-you page), the JSON
  submission (`POST /api/forms/:slug`), honeypot fake-success, and the
  per-IP rate limit.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fc-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp form!(attrs \\ %{}, opts \\ []) do
    actor = admin()
    opts = Keyword.put(opts, :actor, actor)

    form =
      CMS.create_form!(
        Map.merge(
          %{
            name: "Contact",
            slug: "fc-#{System.unique_integer([:positive])}",
            success_message: "Merci!"
          },
          attrs
        ),
        opts
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Email", field_type: :email, required: true},
      opts
    )

    CMS.create_form_field!(
      %{form_id: form.id, name: "message", label: "Message", field_type: :text},
      opts
    )

    form
  end

  # Every test gets its own IP so the tight :form bucket never crosses tests.
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

  # A field named like the honeypot from before #2267 can't be created any
  # more, but a form that already has one keeps working exactly as before
  # (the owner's decision): it renders, an empty value submits, and a filled
  # one trips the honeypot. The honeypot's name is unchanged for headless
  # clients.
  describe "a form with a legacy field named like the honeypot (#2267)" do
    defp legacy_form! do
      form = form!()

      Ash.Seed.seed!(KilnCMS.CMS.FormField, %{
        form_id: form.id,
        name: KilnCMS.Forms.honeypot_field(),
        label: "Your website",
        field_type: :string,
        position: 2
      })

      form
    end

    test "the page renders the field", %{conn: conn} do
      form = legacy_form!()

      html = conn |> get("/forms/#{form.slug}") |> html_response(200)

      assert html =~ "Your website"
    end

    test "a submission that leaves it empty is stored", %{conn: conn} do
      form = legacy_form!()

      html =
        conn
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"email" => "a@b.co", "website" => ""})
        |> html_response(200)

      assert html =~ "Merci!"
      assert [submission] = CMS.recent_form_submissions!(form.id, authorize?: false)
      assert submission.data == %{"email" => "a@b.co"}
    end

    test "a submission that fills it is a fake success, nothing stored", %{conn: conn} do
      form = legacy_form!()

      html =
        conn
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"email" => "a@b.co", "website" => "https://a.example"})
        |> html_response(200)

      assert html =~ "Merci!"
      assert CMS.recent_form_submissions!(form.id, authorize?: false) == []
    end

    test "GET /api/forms/:slug keeps the honeypot's name and lists the field", %{conn: conn} do
      form = legacy_form!()

      body = conn |> get("/api/forms/#{form.slug}") |> json_response(200)

      assert body["honeypot_field"] == "website"
      assert Enum.map(body["fields"], & &1["name"]) == ["email", "message", "website"]
    end
  end

  # #2338: the on-site thank-you and not-found pages render inside the site's
  # public chrome, for the request's org and locale, like the 422 re-render.
  # The embedded variants stay chrome-free (form_embed_test.exs).
  describe "the on-site thank-you and not-found pages (#2338)" do
    defp doc(html), do: LazyHTML.from_document(html)
    defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()
    defp csp(conn), do: get_resp_header(conn, "content-security-policy")

    test "a successful submission answers inside the public chrome", %{conn: conn} do
      form = form!()

      conn = conn |> unique_ip() |> post("/forms/#{form.slug}", %{"email" => "a@b.co"})

      html = html_response(conn, 200)
      d = doc(html)
      assert LazyHTML.query(d, ".public-shell main#main h1") |> Enum.count() == 1
      assert String.trim(text(d, "main#main h1")) == "Thank you"
      assert text(d, "main#main") =~ "Merci!"
      assert text(d, ".public-site-name") =~ KilnCMS.Branding.for_org(nil).site_name
      assert text(d, "title") =~ "Thank you"
      refute html =~ "kiln-embed-body"
      refute html =~ "/embed-frame.js"
    end

    test "a tripped honeypot renders the identical page", %{conn: conn} do
      form = form!()

      real =
        conn
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"email" => "a@b.co"})
        |> html_response(200)

      fake =
        build_conn()
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"email" => "a@b.co", "website" => "http://spam.example"})
        |> html_response(200)

      assert main_html(fake) == main_html(real)
      assert text(doc(fake), "title") == text(doc(real), "title")
      assert [_stored] = CMS.recent_form_submissions!(form.id, authorize?: false)
    end

    test "an unknown slug 404s inside the public chrome with a 404 heading", %{conn: conn} do
      html =
        conn
        |> unique_ip()
        |> post("/forms/fc-none-#{System.unique_integer([:positive])}", %{"email" => "a@b.co"})
        |> html_response(404)

      d = doc(html)
      assert LazyHTML.query(d, ".public-shell main#main h1") |> Enum.count() == 1
      assert String.trim(text(d, "main#main h1")) == "Form not found"
      refute html =~ "Something needs fixing"
      refute html =~ "kiln-embed-body"
      refute html =~ "/embed-frame.js"
    end

    test "an inactive form 404s the same way", %{conn: conn} do
      form = form!(%{active: false})

      html =
        conn
        |> unique_ip()
        |> post("/forms/#{form.slug}", %{"email" => "a@b.co"})
        |> html_response(404)

      assert String.trim(text(doc(html), "main#main h1")) == "Form not found"
      refute html =~ "Merci!"
    end

    test "the Back link appears only for a same-origin referer" do
      form = form!()

      post_with = fn referer ->
        build_conn()
        |> unique_ip()
        |> then(&if(referer, do: put_req_header(&1, "referer", referer), else: &1))
        |> post("/forms/#{form.slug}", %{"email" => "a@b.co"})
        |> html_response(200)
        |> doc()
        |> LazyHTML.query("main#main a.btn")
        |> LazyHTML.attribute("href")
      end

      assert post_with.("http://www.example.com/contact?x=1") == ["/contact"]
      assert post_with.("https://evil.example/contact") == []
      # Same host, but a path a browser reads as another host.
      assert post_with.("http://www.example.com//evil.example/x") == []
      assert post_with.("http://www.example.com/\\evil.example/x") == []
      assert post_with.(nil) == []
    end

    test "under /fr/, the page is French", %{conn: conn} do
      form = form!(%{success_message: nil})

      html =
        conn
        |> unique_ip()
        |> post("/fr/forms/#{form.slug}", %{"email" => "a@b.co"})
        |> html_response(200)

      d = doc(html)
      assert d |> LazyHTML.query("html") |> LazyHTML.attribute("lang") == ["fr"]
      assert String.trim(text(d, "main#main h1")) == "Merci"
      assert text(d, "main#main") =~ "Merci — nous avons bien reçu votre message."
      # The chrome is French too (the stock header links).
      assert text(d, ".public-header nav") =~ "Rechercher"
    after
      Gettext.put_locale(KilnCMSWeb.Gettext, "en")
    end

    test "on another site's host, the page carries that site's branding", %{conn: conn} do
      other = org("fc-other")
      Ash.Seed.seed!(KilnCMS.CMS.SiteBranding, %{org_id: other.id, site_name: "Other Press"})
      KilnCMS.Cache.bust_branding(other.id)
      on_exit(fn -> KilnCMS.Cache.bust_branding(other.id) end)

      form = form!(%{}, tenant: other.id)

      html =
        conn
        |> unique_ip()
        |> org_conn(other)
        |> post("/forms/#{form.slug}", %{"email" => "a@b.co"})
        |> html_response(200)

      d = doc(html)
      assert String.trim(text(d, ".public-site-name")) == "Other Press"
      assert text(d, "main#main") =~ "Merci!"
    end

    test "the thank-you page carries the same CSP as the 422 re-render", %{conn: conn} do
      form = form!()

      ok = conn |> unique_ip() |> post("/forms/#{form.slug}", %{"email" => "a@b.co"})
      bad = build_conn() |> unique_ip() |> post("/forms/#{form.slug}", %{"email" => "nope"})

      assert ok.status == 200
      assert bad.status == 422
      assert [policy] = csp(ok)
      assert csp(bad) == [policy]
      assert policy =~ "frame-ancestors 'self'"
    end
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

    # Not "send exactly the limit, then assert the next one is denied" (#697):
    # `KilnCMSWeb.RateLimit` buckets are FIXED windows, so a rollover anywhere
    # across those requests resets the counter and the following one is
    # legitimately allowed — a 200 that reads as the limiter having failed.
    # Wall-clock dependent, so it was pure luck of when in the minute CI
    # happened to run this.
    #
    # Keep posting until one is denied instead, bounded at 3x the limit so a
    # single rollover cannot exhaust the attempts and a genuinely broken
    # limiter still fails rather than looping.
    {limit, _scale} = Map.fetch!(KilnCMSWeb.RateLimit.limits(), :form)

    denied =
      Enum.reduce_while(1..(limit * 3), nil, fn _, _acc ->
        conn =
          build_conn()
          |> Map.put(:remote_ip, ip)
          |> post("/forms/#{form.slug}", %{"email" => "a@b.co"})

        if conn.status == 429, do: {:halt, conn}, else: {:cont, nil}
      end)

    # Named rather than left to `denied.status` raising on `nil`: "submissions
    # were never rate limited" is the abuse regression this test exists to
    # catch, and it must not read as the test itself being broken.
    assert denied, "the :form bucket allowed #{limit * 3} submissions without denying one"
    assert denied.status == 429
    assert get_resp_header(denied, "retry-after") != []
  end
end
