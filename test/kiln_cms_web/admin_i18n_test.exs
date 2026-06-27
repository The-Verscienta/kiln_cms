defmodule KilnCMSWeb.AdminI18nTest do
  @moduledoc """
  The admin UI locale is chosen via the session (set by `LocaleController`) and
  restored into LiveViews by the `:restore_locale` on_mount hook, localizing the
  UI through Gettext.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias KilnCMS.CMS.Page

  @password "password123456"

  defp editor do
    email = "admin-i18n-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })

    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

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

  describe "LocaleController" do
    test "persists a supported locale to the session and redirects", %{conn: conn} do
      conn = get(conn, ~p"/locale/fr")
      assert get_session(conn, "locale") == "fr"
      assert redirected_to(conn) == ~p"/editor"
    end

    test "ignores an unsupported locale", %{conn: conn} do
      conn = get(conn, ~p"/locale/de")
      assert get_session(conn, "locale") == nil
    end
  end

  describe "admin UI localization" do
    test "the editor renders in the session locale", %{conn: conn} do
      user = editor()

      # Seed a draft so the state badge ("Brouillon" in fr) appears in the content list.
      Ash.Seed.seed!(Page, %{
        title: "i18n draft",
        slug: "i18n-draft-#{System.unique_integer([:positive])}",
        state: :draft
      })

      conn =
        conn
        |> log_in(user)
        |> Plug.Conn.put_session("locale", "fr")

      {:ok, _lv, html} = live(conn, ~p"/editor")

      # From priv/gettext/fr: "Content" → "Contenu", "Analytics" → "Statistiques".
      assert html =~ "Contenu"
      assert html =~ "Statistiques"
      refute html =~ ">Taxonomy<"

      # State labels are translated via state_label/1 + state_badge component.
      assert html =~ "Brouillon"
    end

    test "defaults to English without a locale preference", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in(editor()) |> live(~p"/editor")
      assert html =~ "Taxonomy"
    end
  end
end
