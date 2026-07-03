defmodule KilnCMSWeb.Plugs.SetLocaleTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Plug.Test

  alias KilnCMSWeb.Plugs.SetLocale

  defp run(path), do: conn(:get, path) |> SetLocale.call([])

  test "strips a known non-default locale prefix and assigns the locale" do
    conn = run("/fr/about")
    assert conn.assigns.locale == "fr"
    assert conn.path_info == ["about"]
    assert conn.request_path == "/about"
  end

  test "strips the default locale prefix too" do
    conn = run("/en/blog/post")
    assert conn.assigns.locale == "en"
    assert conn.path_info == ["blog", "post"]
  end

  test "defaults the locale when there is no prefix" do
    conn = run("/about")
    assert conn.assigns.locale == "en"
    assert conn.path_info == ["about"]
  end

  test "leaves an unsupported prefix untouched (it is just a path segment)" do
    conn = run("/de/about")
    assert conn.assigns.locale == "en"
    assert conn.path_info == ["de", "about"]
  end

  test "a bare one-segment path is never treated as a locale" do
    conn = run("/fr")
    assert conn.assigns.locale == "en"
    assert conn.path_info == ["fr"]
  end

  describe "session fallback (admin language switcher)" do
    defp run_with_session(path, session) do
      conn(:get, path)
      |> Plug.Test.init_test_session(session)
      |> SetLocale.call([])
    end

    test "uses the session locale when there is no path prefix" do
      conn = run_with_session("/editor", %{"locale" => "fr"})
      assert conn.assigns.locale == "fr"
    end

    test "a path prefix wins over the session preference" do
      conn = run_with_session("/en/blog/post", %{"locale" => "fr"})
      assert conn.assigns.locale == "en"
    end

    test "an unsupported session locale falls back to the default" do
      conn = run_with_session("/editor", %{"locale" => "xx"})
      assert conn.assigns.locale == "en"
    end
  end
end
