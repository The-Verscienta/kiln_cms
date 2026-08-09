defmodule KilnCMSWeb.TranslationsLiveTest do
  @moduledoc """
  Localization workflows in the admin UIs: the coverage dashboard
  (`/editor/translations`) shows per-locale chips and creates missing
  translations in place, and the content editor's Translations panel links
  siblings, marks outdated ones, and creates drafts.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "trl-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
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

  defp slug, do: "trl-#{System.unique_integer([:positive])}"

  describe "dashboard" do
    test "groups content by slug with per-locale chips and outdated markers", %{conn: conn} do
      admin = authed_admin()
      shared = slug()

      en = CMS.create_page!(%{title: "Coverage EN", slug: shared, locale: "en"}, actor: admin)
      fr = CMS.create_page!(%{title: "Coverage FR", slug: shared, locale: "fr"}, actor: admin)
      _ = CMS.publish_page!(fr, %{}, actor: admin)
      # Editing the source after the translation makes fr outdated.
      CMS.update_page!(en, %{title: "Coverage EN v2"}, actor: admin)

      {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/translations")

      assert html =~ "Coverage EN v2"
      assert html =~ "published"
      assert html =~ "Outdated"
      # The es column offers creation.
      assert html =~ "missing"
    end

    test "a missing chip creates the draft translation and opens its editor", %{conn: conn} do
      admin = authed_admin()

      en =
        CMS.create_page!(%{title: "To translate", slug: slug(), locale: "en"}, actor: admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/translations")

      lv
      |> element(
        ~s(button[phx-click="create_translation"][phx-value-id="#{en.id}"][phx-value-locale="fr"])
      )
      |> render_click()

      assert_redirect(lv)

      [fr] =
        CMS.list_pages!(
          actor: admin,
          query: [filter: [slug: en.slug, locale: "fr"]]
        )

      assert fr.state == :draft
      assert fr.title == "To translate"
    end
  end

  describe "XLIFF vendor round trip (#502)" do
    test "ticking a row builds an export link for the chosen target locale", %{conn: conn} do
      admin = authed_admin()
      en = CMS.create_page!(%{title: "Send out", slug: slug(), locale: "en"}, actor: admin)

      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/translations")

      # Nothing selected yet: no link, and the default target is the first
      # non-default locale.
      assert html =~ "Tick a row to export."
      refute has_element?(lv, ~s(a[href*="export.xlf"]))

      lv
      |> element(~s(input[phx-click="toggle_export"][phx-value-key="page:#{en.id}"]))
      |> render_click()

      assert has_element?(
               lv,
               ~s(a[href="/editor/translations/export.xlf?record[]=page%3A#{en.id}&target=fr"])
             )

      # Switching the target locale rebuilds the same link for `es`.
      lv |> element("#xliff-locale") |> render_change(%{"locale" => "es"})
      assert has_element?(lv, ~s(a[href*="target=es"]))

      # And clearing drops the selection entirely.
      lv |> element(~s(button[phx-click="clear_export"])) |> render_click()
      refute has_element?(lv, ~s(a[href*="export.xlf"]))
    end

    test "a row with no default-locale source cannot be exported", %{conn: conn} do
      admin = authed_admin()
      _fr = CMS.create_page!(%{title: "Only French", slug: slug(), locale: "fr"}, actor: admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/translations")

      assert has_element?(lv, ~s(input[phx-click="toggle_export"][disabled]))
    end

    test "uploading a returned file applies it and reports every unit", %{conn: conn} do
      admin = authed_admin()

      en =
        CMS.create_page!(
          %{
            title: "Vendor job",
            slug: slug(),
            locale: "en",
            blocks: [%{"_type" => "heading", "text" => "Chapter one"}]
          },
          actor: admin
        )

      {:ok, %{xliff: xml}} =
        KilnCMS.CMS.Xliff.export(:page, CMS.get_page!(en.id, actor: admin), "fr", actor: admin)

      translated =
        String.replace(xml, ~r{</source>}, ~s(</source><target xml:space="preserve">FR</target>))

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/translations")

      lv
      |> file_input("#xliff-import", :xliff, [
        %{name: "job.xlf", content: translated, type: "application/xliff+xml"}
      ])
      |> render_upload("job.xlf")

      html = lv |> element("#xliff-import") |> render_submit()

      assert html =~ "Import result"
      assert html =~ "job.xlf"
      assert html =~ "2 applied"

      [fr] = CMS.list_pages!(actor: admin, query: [filter: [slug: en.slug, locale: "fr"]])
      assert fr.title == "FR"
      assert [%Ash.Union{value: heading}] = fr.blocks
      assert heading.text == "FR"
    end

    test "a file that is not XLIFF is refused with a reason", %{conn: conn} do
      admin = authed_admin()
      _en = CMS.create_page!(%{title: "Nope", slug: slug(), locale: "en"}, actor: admin)

      {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/translations")

      lv
      |> file_input("#xliff-import", :xliff, [
        %{name: "not-xliff.xml", content: "<html><body>hi</body></html>", type: "text/xml"}
      ])
      |> render_upload("not-xliff.xml")

      html = lv |> element("#xliff-import") |> render_submit()

      assert html =~ "not an XLIFF 2.0 file"
    end
  end

  describe "editor panel" do
    test "lists sibling locales and creates a missing translation", %{conn: conn} do
      admin = authed_admin()
      shared = slug()

      en = CMS.create_page!(%{title: "Panel EN", slug: shared, locale: "en"}, actor: admin)
      _fr = CMS.create_page!(%{title: "Panel FR", slug: shared, locale: "fr"}, actor: admin)

      {:ok, lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{en.id}")

      assert html =~ "Translations"
      assert html =~ "(this one)"
      # fr exists (linked), es is creatable.
      assert has_element?(lv, ~s(button[phx-click="create_translation"][phx-value-locale="es"]))
      refute has_element?(lv, ~s(button[phx-click="create_translation"][phx-value-locale="fr"]))

      lv
      |> element(~s(button[phx-click="create_translation"][phx-value-locale="es"]))
      |> render_click()

      assert_redirect(lv)
      assert [_es] = CMS.list_pages!(actor: admin, query: [filter: [slug: shared, locale: "es"]])
    end

    test "marks an outdated sibling", %{conn: conn} do
      admin = authed_admin()
      shared = slug()

      en = CMS.create_page!(%{title: "Stale EN", slug: shared, locale: "en"}, actor: admin)
      _fr = CMS.create_page!(%{title: "Stale FR", slug: shared, locale: "fr"}, actor: admin)
      en = CMS.update_page!(en, %{title: "Stale EN v2"}, actor: admin)

      {:ok, _lv, html} = conn |> log_in(admin) |> live(~p"/editor/content/page/#{en.id}")

      assert html =~ "Outdated"
    end
  end
end
