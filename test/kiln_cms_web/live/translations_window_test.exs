defmodule KilnCMSWeb.TranslationsWindowTest do
  @moduledoc """
  The coverage dashboard's per-type window (#2761) is taken on slugs, not
  records: every variant of a slug inside the window is shown, however far
  back its own last edit is.

  `async: false` because the window is `config :kiln_cms,
  KilnCMSWeb.TranslationsLive, per_type_limit:`, read at mount, and
  application env is VM-global — lowering it from an async test would cap
  every other dashboard that mounted while this one ran.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMSWeb.TranslationsLive)
    Application.put_env(:kiln_cms, KilnCMSWeb.TranslationsLive, per_type_limit: 2)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, KilnCMSWeb.TranslationsLive, previous),
        else: Application.delete_env(:kiln_cms, KilnCMSWeb.TranslationsLive)
    end)
  end

  defp authed_admin do
    email = "trw-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp slug, do: "trw-#{System.unique_integer([:positive])}"

  defp page!(admin, title, slug, locale),
    do: CMS.create_page!(%{title: title, slug: slug, locale: locale}, actor: admin)

  test "a translation older than the window's newest records is shown, not missing",
       %{conn: conn} do
    admin = authed_admin()
    shared = slug()

    # Oldest first: with a two-record window, fr is the record that falls out.
    fr = page!(admin, "Ancien", shared, "fr")
    en = page!(admin, "Old source", shared, "en")
    _newer = page!(admin, "Newer", slug(), "en")

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/translations")

    assert has_element?(lv, ~s(#row-page-#{en.id} a[href="/editor/content/page/#{fr.id}"]))

    refute has_element?(
             lv,
             ~s(button[phx-click="create_translation"][phx-value-id="#{en.id}"][phx-value-locale="fr"])
           )
  end

  test "a slug whose default-locale source is older than the window can still be exported",
       %{conn: conn} do
    admin = authed_admin()
    shared = slug()

    en = page!(admin, "Source", shared, "en")
    fr = page!(admin, "Traduction", shared, "fr")
    _newer = page!(admin, "Newer", slug(), "en")

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/translations")

    # The row is represented by its en source, not the fr variant.
    refute has_element?(lv, "#row-page-#{fr.id}")
    assert has_element?(lv, ~s(#row-page-#{en.id} input[type="checkbox"]))
    refute has_element?(lv, ~s(#row-page-#{en.id} input[type="checkbox"][disabled]))
  end

  test "the window counts slugs, and a slug with no default-locale variant takes a place",
       %{conn: conn} do
    admin = authed_admin()

    oldest = page!(admin, "Oldest", slug(), "en")
    fr_only = page!(admin, "Seulement", slug(), "fr")
    newest = page!(admin, "Newest", slug(), "en")

    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/translations")

    assert has_element?(lv, "#row-page-#{newest.id}")
    assert has_element?(lv, "#row-page-#{fr_only.id}")
    refute has_element?(lv, "#row-page-#{oldest.id}")
  end
end
