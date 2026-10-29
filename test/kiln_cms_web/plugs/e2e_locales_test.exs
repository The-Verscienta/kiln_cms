defmodule KilnCMSWeb.Plugs.E2ELocalesTest do
  @moduledoc false
  # Rewrites the VM-global `:i18n` config, which every request reads — so not
  # async (see `KilnCMS.I18n.locales/0`).
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias KilnCMS.I18n
  alias KilnCMSWeb.Plugs.E2ELocales

  setup do
    previous = Application.get_env(:kiln_cms, :i18n)
    Application.put_env(:kiln_cms, :i18n, Keyword.put(previous, :locales, ["en"]))
    on_exit(fn -> Application.put_env(:kiln_cms, :i18n, previous) end)
  end

  defp call(method, params) do
    conn(method, "/", params) |> E2ELocales.call(E2ELocales.init([]))
  end

  test "POST sets the locales and answers with the list it had" do
    conn = call(:post, %{"locales" => ["en", "fr"]})
    assert conn.status == 200
    assert conn.halted
    assert Jason.decode!(conn.resp_body) == %{"locales" => ["en", "fr"], "was" => ["en"]}
    assert I18n.locales() == ["en", "fr"]
    assert I18n.default_locale() == "en"

    conn = call(:post, %{"locales" => ["en"]})
    assert Jason.decode!(conn.resp_body) == %{"locales" => ["en"], "was" => ["en", "fr"]}
    assert I18n.locales() == ["en"]
  end

  test "a list without the default locale is refused and changes nothing" do
    conn = call(:post, %{"locales" => ["fr"]})
    assert conn.status == 400
    assert I18n.locales() == ["en"]
  end

  test "a malformed locale or a non-list is refused" do
    assert call(:post, %{"locales" => ["en", "fr\n<script>"]}).status == 400
    assert call(:post, %{"locales" => "en,fr"}).status == 400
    assert call(:post, %{}).status == 400
    assert I18n.locales() == ["en"]
  end

  test "a GET changes nothing" do
    conn = call(:get, %{"locales" => ["en", "fr"]})
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["POST"]
    assert I18n.locales() == ["en"]
  end
end
