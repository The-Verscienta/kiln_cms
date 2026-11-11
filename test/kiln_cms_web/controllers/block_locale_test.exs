defmodule KilnCMSWeb.BlockLocaleTest do
  @moduledoc """
  The strings Kiln writes into a page's article — a form's labels, a sign-up
  block's fields, an embed's fallback title, the byline — are in the page's
  language, the one `<article lang>` declares, not the request's (#2465). The
  chrome around it, `<html lang>` included, is the request's (#2595). And on a
  multi-locale site (the test config: en, fr, es) a form or sign-up posts to a
  path pinned to that language, so the response to it is in it too.
  """
  # Not async: these read through the published-payload cache, one global
  # Cachex table, and `setup` clears it; the single-locale test also swaps the
  # `:i18n` application env.
  use KilnCMSWeb.ConnCase, async: false

  # Publishing logs that it stores unsigned provenance in test.
  @moduletag :capture_log

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import KilnCMS.FormFixtures, only: [admin: 0, form!: 0, form!: 1]

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMSWeb.BlockComponents

  setup do
    KilnCMS.Cache.bust_published()
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{
          title: "Locale page",
          slug: "locale-#{uniq()}",
          state: :published,
          published_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp newsletter(attrs \\ %{}),
    do: Map.merge(%{"_type" => "newsletter_signup", "collect_name" => true}, attrs)

  # A form with a required email (the fixture's) and a select, placed on a page.
  defp form_with_select!(attrs \\ %{}) do
    form = form!(attrs)

    CMS.create_form_field!(
      %{form_id: form.id, name: "topic", label: "Topic", field_type: :select, options: ["A"]},
      actor: admin()
    )

    form
  end

  defp form_block(form), do: %{"_type" => "form", "form_slug" => form.slug}

  defp doc(html), do: LazyHTML.from_document(html)

  defp one(html, selector) do
    [node] = html |> doc() |> LazyHTML.query(selector) |> Enum.to_list()
    node
  end

  defp action(html, selector), do: html |> one(selector) |> LazyHTML.attribute("action") |> hd()

  defp text(html, selector), do: html |> one(selector) |> LazyHTML.text()

  # A signed-in reader holding `audiences`, as `PaywallDeliveryTest` makes one:
  # the session needs the token a real sign-in mints.
  defp member(audiences) do
    email = "locale-member-#{uniq()}@example.com"

    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer,
      audiences: audiences
    })

    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => "password123456"},
        []
      )

    user
  end

  defp csp(conn), do: conn |> get_resp_header("content-security-policy") |> List.first()

  # A visitor whose session says French: an unprefixed request answers in it.
  defp french_session(conn), do: Phoenix.ConnTest.init_test_session(conn, %{"locale" => "fr"})

  describe "a newsletter sign-up block" do
    test "on an English page served at /fr/ is in English and posts to /en/", %{conn: conn} do
      page = page(%{locale: "en", blocks: [newsletter()]})

      for request <- [conn, build_conn()] do
        # The second request is a payload-cache hit.
        html = request |> get("/fr/#{page.slug}") |> html_response(200)

        assert html |> one("html") |> LazyHTML.attribute("lang") == ["fr"]
        assert html |> one("article.public-article") |> LazyHTML.attribute("lang") == ["en"]
        form = text(html, "form.kiln-newsletter-signup")
        assert form =~ "Email"
        assert form =~ "Name"
        assert form =~ "Leave this field empty"
        refute form =~ "Laissez ce champ vide"
        assert action(html, "form.kiln-newsletter-signup") == "/en/newsletter/subscribe"
      end
    end

    test "on a French page is in French and posts to /fr/", %{conn: conn} do
      page = page(%{locale: "fr", blocks: [newsletter()]})

      html = conn |> get("/fr/#{page.slug}") |> html_response(200)

      form = text(html, "form.kiln-newsletter-signup")
      assert form =~ "E-mail"
      assert form =~ "Nom"
      assert form =~ "Laissez ce champ vide"
      assert action(html, "form.kiln-newsletter-signup") == "/fr/newsletter/subscribe"
    end

    test "inside columns posts to the pinned path too", %{conn: conn} do
      page =
        page(%{
          locale: "fr",
          blocks: [
            %{
              "_type" => "columns",
              "layout" => "1-1",
              "columns" => [%{"blocks" => [newsletter()]}, %{"blocks" => []}]
            }
          ]
        })

      html = conn |> get("/fr/#{page.slug}") |> html_response(200)

      assert action(html, "form.kiln-newsletter-signup") == "/fr/newsletter/subscribe"
      assert text(html, "form.kiln-newsletter-signup") =~ "Laissez ce champ vide"
    end

    test "posting to the pinned French action answers in French and subscribes", %{conn: conn} do
      page = page(%{locale: "fr", blocks: [newsletter()]})
      html = conn |> get("/fr/#{page.slug}") |> html_response(200)
      email = "pinned-#{uniq()}@example.com"

      response =
        build_conn()
        |> unique_ip()
        |> post(action(html, "form.kiln-newsletter-signup"), %{
          "email" => email,
          KilnCMS.Forms.honeypot_field() => ""
        })
        |> html_response(200)

      assert response =~ "Consultez votre boîte de réception"

      assert [%{status: :pending}] =
               KilnCMS.Newsletter.Subscriber
               |> Ash.Query.filter(email == ^email)
               |> Ash.read!(authorize?: false)
    end

    test "a member's uncached, gated read is in the page's language", %{conn: conn} do
      actor = admin()
      gated = hd(KilnCMS.CMS.Audiences.gated())

      {:ok, post} =
        CMS.create_post(
          %{
            title: "Gated",
            slug: "gated-#{uniq()}",
            locale: "en",
            audience: gated,
            blocks: [newsletter()]
          },
          actor: actor
        )

      {:ok, post} = CMS.publish_post(post, %{}, actor: actor)

      html =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> AshAuthentication.Plug.Helpers.store_in_session(member([gated]))
        |> get("/fr/blog/#{post.slug}")
        |> html_response(200)

      # The body, so the member render, not the teaser.
      assert text(html, "form.kiln-newsletter-signup") =~ "Leave this field empty"
    end
  end

  describe "a form block" do
    test "on an English page served at /fr/ is in English and posts to /en/", %{conn: conn} do
      form = form_with_select!()
      page = page(%{locale: "en", blocks: [form_block(form)]})

      html = conn |> get("/fr/#{page.slug}") |> html_response(200)

      form_text = text(html, "form.kiln-form")
      assert form_text =~ "Submit"
      assert form_text =~ "required"
      assert form_text =~ "Select…"
      assert form_text =~ "Leave this field empty"
      refute form_text =~ "Soumettre"
      refute form_text =~ "obligatoire"
      assert action(html, "form.kiln-form") == "/en/forms/#{form.slug}"
    end

    test "on a French page is in French and posts to /fr/", %{conn: conn} do
      form = form_with_select!()
      page = page(%{locale: "fr", blocks: [form_block(form)]})

      html = conn |> get("/fr/#{page.slug}") |> html_response(200)

      form_text = text(html, "form.kiln-form")
      assert form_text =~ "Soumettre"
      assert form_text =~ "obligatoire"
      assert form_text =~ "Sélectionner…"
      assert action(html, "form.kiln-form") == "/fr/forms/#{form.slug}"
    end

    # The visitor's session says French, so a bare action would answer in
    # French; the pinned one answers in the English page's language.
    test "a refusal posted from an English page re-renders in English", %{conn: conn} do
      form = form_with_select!()
      page = page(%{locale: "en", blocks: [form_block(form)]})
      page_html = conn |> get("/fr/#{page.slug}") |> html_response(200)
      action = action(page_html, "form.kiln-form")

      html =
        build_conn()
        |> french_session()
        |> unique_ip()
        |> post(action, %{"email" => "nope"})
        |> html_response(422)

      assert html =~ "There is a problem with your submission"
      refute html =~ "Ce champ"
      assert action(html, "form.kiln-form") == "/en/forms/#{form.slug}"
    end

    test "a refusal posted from a French page re-renders in French", %{conn: conn} do
      form = form_with_select!()
      page = page(%{locale: "fr", blocks: [form_block(form)]})
      page_html = conn |> get("/fr/#{page.slug}") |> html_response(200)

      html =
        build_conn()
        |> unique_ip()
        |> post(action(page_html, "form.kiln-form"), %{"email" => "nope"})
        |> html_response(422)

      refute html =~ "There is a problem with your submission"
      assert html =~ "Soumettre"
      assert action(html, "form.kiln-form") == "/fr/forms/#{form.slug}"
    after
      Gettext.put_locale(KilnCMSWeb.Gettext, "en")
    end

    test "the thank-you page is in the page's language", %{conn: conn} do
      form = form_with_select!(%{success_message: nil})
      page = page(%{locale: "fr", blocks: [form_block(form)]})
      page_html = conn |> get("/fr/#{page.slug}") |> html_response(200)

      html =
        build_conn()
        |> unique_ip()
        |> post(action(page_html, "form.kiln-form"), %{
          "email" => "reader@example.com",
          KilnCMS.Forms.rendered_at_field() =>
            page_html
            |> one("input[name='#{KilnCMS.Forms.rendered_at_field()}']")
            |> LazyHTML.attribute("value")
            |> hd()
        })
        |> html_response(200)

      assert html =~ "Merci — nous avons bien reçu votre message."
    after
      Gettext.put_locale(KilnCMSWeb.Gettext, "en")
    end
  end

  describe "the form embed" do
    test "served under /fr/ posts to /fr/ and re-renders a refusal in French", %{conn: conn} do
      form = form!()
      embed = conn |> unique_ip() |> get("/fr/forms/#{form.slug}/embed")
      embed_html = html_response(embed, 200)

      assert action(embed_html, "form.kiln-form") == "/fr/forms/#{form.slug}"

      refused =
        build_conn()
        |> unique_ip()
        |> post("/fr/forms/#{form.slug}", %{"email" => "nope", "_kiln_embed" => "1"})

      html = html_response(refused, 422)
      assert html =~ "Soumettre"
      assert html =~ "/embed-frame.js"
      assert action(html, "form.kiln-form") == "/fr/forms/#{form.slug}"
      assert csp(refused) == csp(embed)
    after
      Gettext.put_locale(KilnCMSWeb.Gettext, "en")
    end

    # The URL's locale is the default when there is no prefix (#2595), and it
    # is pinned like any other: a bare action would answer in the session's.
    test "served unprefixed posts under the default locale's prefix", %{conn: conn} do
      form = form!()

      html =
        conn
        |> french_session()
        |> unique_ip()
        |> get("/forms/#{form.slug}/embed")
        |> html_response(200)

      assert action(html, "form.kiln-form") == "/en/forms/#{form.slug}"
      assert html =~ "Submit"
      refute html =~ "Soumettre"
    end
  end

  test "an untitled embed's title is in the page's language", %{conn: conn} do
    embed = %{"_type" => "embed", "url" => "https://www.youtube.com/watch?v=abc123"}
    en = page(%{locale: "en", blocks: [embed]})
    fr = page(%{locale: "fr", blocks: [embed]})

    assert conn |> get("/fr/#{en.slug}") |> html_response(200) =~ ~s(title="Embedded media")

    assert build_conn() |> get("/fr/#{fr.slug}") |> html_response(200) =~
             ~s(title="Média intégré")
  end

  test "a post's byline date follows the page's language", %{conn: conn} do
    actor = admin()
    {:ok, post} = CMS.create_post(%{title: "Dated", slug: "dated-#{uniq()}"}, actor: actor)
    {:ok, post} = CMS.publish_post(post, %{}, actor: actor)

    html = conn |> get("/fr/blog/#{post.slug}") |> html_response(200)

    english =
      Gettext.with_locale(KilnCMSWeb.Gettext, "en", fn ->
        KilnCMSWeb.ContentHTML.published_on(post.published_at)
      end)

    french =
      Gettext.with_locale(KilnCMSWeb.Gettext, "fr", fn ->
        KilnCMSWeb.ContentHTML.published_on(post.published_at)
      end)

    assert text(html, "article .public-meta") =~ english
    refute text(html, "article .public-meta") =~ french
  end

  describe "a block rendered outside a page (the previews)" do
    test "posts to the bare paths" do
      html =
        render_component(&BlockComponents.render_block/1,
          block: %{type: "newsletter_signup", content: "News", id: "n1", button_label: "Go"}
        )

      assert html =~ ~s(action="/newsletter/subscribe")
    end
  end

  describe "a single-locale site" do
    setup do
      previous = Application.get_env(:kiln_cms, :i18n)
      Application.put_env(:kiln_cms, :i18n, default_locale: "en", locales: ["en"])
      on_exit(fn -> Application.put_env(:kiln_cms, :i18n, previous) end)
    end

    test "keeps the bare submit paths", %{conn: conn} do
      page = page(%{locale: "en", blocks: [newsletter()]})

      html = conn |> get("/#{page.slug}") |> html_response(200)

      assert action(html, "form.kiln-newsletter-signup") == "/newsletter/subscribe"
      assert KilnCMS.I18n.pinned_path("en", "/forms/x") == "/forms/x"
    end
  end
end
