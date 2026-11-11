defmodule KilnCMSWeb.FormPageTest do
  @moduledoc """
  The form's own public page, `GET /forms/:slug` (#2138).

  It is not a route: it is the last fallback of `KilnCMSWeb.ContentController`'s
  miss funnel for a `/forms/<slug>` URL, so half of these tests are about what
  must still win over it — a content type of the site's own at `/forms`, a path
  alias, a redirect — and that a miss still 404s and is still recorded.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.OrgFixtures

  alias KilnCMS.CMS

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fp-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp form!(attrs \\ %{}, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :actor, &admin/0)

    form =
      CMS.create_form!(
        Map.merge(
          %{
            name: "Contact the team",
            slug: "fp-#{uniq()}",
            description: "We answer within a day."
          },
          attrs
        ),
        opts
      )

    CMS.create_form_field!(
      %{form_id: form.id, name: "email", label: "Your email", field_type: :email, required: true},
      opts
    )

    form
  end

  # What the funnel recorded, read past the admin-only policy: the test asserts
  # on the tracker's writes, not on who may read the report.
  defp missed_paths do
    CMS.list_missed_paths!(authorize?: false, tenant: KilnCMS.Accounts.default_org_id())
    |> Enum.map(& &1.path)
  end

  describe "an active form" do
    # Posts under the default locale's prefix on this multi-locale site
    # (#2595): an unprefixed POST would answer in the session's language.
    test "is served as a page in the site's chrome, posting to /en/forms/<slug>", %{conn: conn} do
      form = form!()

      conn = get(conn, "/forms/#{form.slug}")
      body = html_response(conn, 200)
      doc = LazyHTML.from_document(body)

      assert body =~ "Contact the team"
      assert body =~ "We answer within a day."
      assert body =~ "Your email"

      assert doc |> LazyHTML.query("form.kiln-form") |> LazyHTML.attribute("action") ==
               ["/en/forms/#{form.slug}"]

      # An on-site submission, not an embedded one: no `_kiln_embed` marker, so
      # the POST answers under the site's own CSP.
      assert doc |> LazyHTML.query(~s(input[name="_kiln_embed"])) |> Enum.count() == 0

      # The public layout, not the transparent iframe document.
      assert doc |> LazyHTML.query(".public-shell header.public-header") |> Enum.count() == 1
      refute body =~ "kiln-embed-body"
      refute body =~ "/embed-frame.js"

      # The site-wide CSP, not the embed's framing policy.
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "frame-ancestors 'self'"
      refute csp =~ "embedder.test"
    end

    test "is shared-cacheable briefly, varies on language, and is not indexed", %{conn: conn} do
      form = form!()

      conn = get(conn, "/forms/#{form.slug}")

      assert conn.status == 200

      assert get_resp_header(conn, "cache-control") == [
               "public, max-age=60, stale-while-revalidate=300"
             ]

      assert get_resp_header(conn, "vary") == ["Accept-Language"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex"]
    end

    test "under a locale prefix, posts back under the same prefix", %{conn: conn} do
      form = form!()

      body = conn |> get("/fr/forms/#{form.slug}") |> html_response(200)

      assert body =~ "Contact the team"

      assert body
             |> LazyHTML.from_document()
             |> LazyHTML.query("form.kiln-form")
             |> LazyHTML.attribute("action") == ["/fr/forms/#{form.slug}"]
    end

    # #2465: the default locale's prefix is kept too — an unprefixed POST
    # would answer in the session's locale, not the page's. The page itself is
    # in the path's locale: a form has no record locale of its own.
    test "under the default locale's prefix, posts back under it", %{conn: conn} do
      form = form!()

      body =
        conn
        |> Phoenix.ConnTest.init_test_session(%{"locale" => "fr"})
        |> get("/en/forms/#{form.slug}")
        |> html_response(200)

      assert body =~ ~s(lang="en")
      assert body =~ "Submit"

      assert body
             |> LazyHTML.from_document()
             |> LazyHTML.query("form.kiln-form")
             |> LazyHTML.attribute("action") == ["/en/forms/#{form.slug}"]
    end

    test "under /fr/, the page's own strings are French", %{conn: conn} do
      form = form!()

      body = conn |> get("/fr/forms/#{form.slug}") |> html_response(200)

      assert body =~ ~s(lang="fr")
      assert body =~ "Soumettre"
      refute body =~ ">Submit<"
    after
      Gettext.put_locale(KilnCMSWeb.Gettext, "en")
    end

    test "a refused submission from the localized page keeps the prefix", %{conn: conn} do
      form = form!()

      body = conn |> post("/fr/forms/#{form.slug}", %{"email" => ""}) |> html_response(422)

      assert body
             |> LazyHTML.from_document()
             |> LazyHTML.query("form.kiln-form")
             |> LazyHTML.attribute("action") == ["/fr/forms/#{form.slug}"]
    end
  end

  describe "no form to serve" do
    test "an inactive form 404s, and the miss is recorded", %{conn: conn} do
      form = form!(%{active: false})

      conn = get(conn, "/forms/#{form.slug}")

      assert html_response(conn, 404) =~ "Page not found"
      refute conn.resp_body =~ "Contact the team"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert "/forms/#{form.slug}" in missed_paths()
    end

    test "an unknown slug 404s as a page, and the miss is recorded", %{conn: conn} do
      slug = "fp-none-#{uniq()}"

      assert conn |> get("/forms/#{slug}") |> html_response(404) =~ "Page not found"
      assert "/forms/#{slug}" in missed_paths()
    end

    test "another site's form is not served on this site's host", %{conn: conn} do
      other = org("fp-other")
      form = form!(%{}, tenant: other)

      # It does answer on its own host…
      assert conn
             |> unique_ip()
             |> org_conn(other)
             |> get("/forms/#{form.slug}")
             |> html_response(200) =~
               "Contact the team"

      # …and not on the default site's.
      body = conn |> unique_ip() |> get("/forms/#{form.slug}") |> html_response(404)
      refute body =~ "Contact the team"
    end
  end

  describe "what still wins at /forms/<slug>" do
    test "a path alias at the same address", %{conn: conn} do
      slug = "fp-alias-#{uniq()}"
      form!(%{slug: slug})

      Ash.Seed.seed!(KilnCMS.CMS.Page, %{
        title: "Aliased page",
        slug: "fp-aliased-#{uniq()}",
        state: :published,
        path_alias: "/forms/#{slug}",
        blocks:
          KilnCMS.TypedFixtures.typed_blocks([
            %{type: :heading, content: "The aliased page body", order: 0}
          ])
      })

      body = conn |> get("/forms/#{slug}") |> html_response(200)

      assert body =~ "The aliased page body"
      refute body =~ "Contact the team"
    end

    test "a redirect from the same address", %{conn: conn} do
      actor = admin()
      slug = "fp-moved-#{uniq()}"
      form!(%{slug: slug}, actor: actor)

      target =
        CMS.create_page!(%{title: "Moved here", slug: "fp-target-#{uniq()}"}, actor: actor)
        |> CMS.publish_page!(actor: actor)

      CMS.create_redirect!(
        %{path: "/forms/#{slug}", locale: "en", target_type: "page", target_id: target.id},
        actor: actor
      )

      assert redirected_to(get(conn, "/forms/#{slug}"), 301) == "/#{target.slug}"
    end

    test "a content type of the site's own at /forms keeps its entries", %{conn: conn} do
      # A site may already serve a type at `/forms` — the segment was never
      # reserved, and this page is a fallback precisely so it stays that way.
      # Its own org, so the type is invisible to every other test.
      actor = admin()
      site = org("fp-forms-type")

      td =
        CMS.create_type_definition!(
          %{name: "forms", label: "Form", plural_label: "Forms", path_segment: "forms"},
          actor: actor,
          tenant: site
        )

      shared = "fp-shared-#{uniq()}"

      CMS.create_entry!(%{title: "The entry wins", slug: shared, type_definition_id: td.id},
        actor: actor,
        tenant: site
      )
      |> CMS.publish_entry!(actor: actor, tenant: site)

      form!(%{slug: shared}, actor: actor, tenant: site)
      only_form = form!(%{name: "Only a form here"}, actor: actor, tenant: site)

      site_conn = fn -> conn |> unique_ip() |> org_conn(site) end

      body = site_conn.() |> get("/forms/#{shared}") |> html_response(200)
      assert body =~ "The entry wins"
      refute body =~ "Contact the team"

      # A slug the type has no entry for still reaches the form.
      assert site_conn.() |> get("/forms/#{only_form.slug}") |> html_response(200) =~
               "Only a form here"
    end
  end
end
