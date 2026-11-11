defmodule KilnCMSWeb.Plugs.UrlLocaleTest do
  @moduledoc false
  # async: false — the plug sets the process's Gettext locale, and the `after`
  # blocks put it back; nothing else is shared, but the assertion on
  # `Gettext.get_locale/1` reads process state the test must own.
  use ExUnit.Case, async: false

  import Plug.Test

  alias KilnCMSWeb.Plugs.SetLocale
  alias KilnCMSWeb.Plugs.UrlLocale

  # SetLocale first, as the endpoint runs it, then this plug, as a delivery
  # controller does.
  defp run(path, session \\ nil) do
    conn = conn(:get, path)
    conn = if session, do: init_test_session(conn, session), else: conn

    conn |> SetLocale.call([]) |> UrlLocale.call([])
  end

  setup do
    on_exit(fn -> Gettext.put_locale(KilnCMSWeb.Gettext, "en") end)
  end

  test "a path prefix is the locale" do
    conn = run("/fr/about")

    assert conn.assigns.locale == "fr"
    assert UrlLocale.locale(conn) == "fr"
    assert Gettext.get_locale(KilnCMSWeb.Gettext) == "fr"
  end

  test "no prefix is the default locale" do
    conn = run("/about")

    assert conn.assigns.locale == "en"
    assert Gettext.get_locale(KilnCMSWeb.Gettext) == "en"
  end

  test "an unprefixed URL ignores the session's locale" do
    conn = run("/about", %{"locale" => "fr"})

    assert conn.assigns.locale == "en"
    assert UrlLocale.locale(conn) == "en"
    assert Gettext.get_locale(KilnCMSWeb.Gettext) == "en"
  end

  test "a prefix wins over the session's locale" do
    conn = run("/es/about", %{"locale" => "fr"})

    assert conn.assigns.locale == "es"
    assert Gettext.get_locale(KilnCMSWeb.Gettext) == "es"
  end

  # `locale/1` reads the stripped prefix, not `assigns.locale`, so a caller
  # that runs where the plug did not still gets the URL's answer.
  test "locale/1 does not read assigns.locale" do
    conn = "/about" |> run_set_locale_only(%{"locale" => "fr"})

    assert conn.assigns.locale == "fr"
    assert UrlLocale.locale(conn) == "en"
  end

  defp run_set_locale_only(path, session) do
    conn(:get, path) |> init_test_session(session) |> SetLocale.call([])
  end
end
