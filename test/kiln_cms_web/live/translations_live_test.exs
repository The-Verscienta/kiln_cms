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
