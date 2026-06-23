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
end
