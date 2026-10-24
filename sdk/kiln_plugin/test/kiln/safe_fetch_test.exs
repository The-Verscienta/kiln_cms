defmodule Kiln.SafeFetchTest do
  @moduledoc """
  `Kiln.SafeFetch` with no KilnCMS core loaded (#2047): it fails closed, and a
  plugin's own test config can stand an implementation in. The core's suite
  tests the facade against the real, pinning implementation.
  """
  # Not async: the implementation is read from the application env.
  use ExUnit.Case, async: false

  defmodule Echo do
    @moduledoc false
    @behaviour Kiln.SafeFetch

    @impl Kiln.SafeFetch
    def request(method, url, opts),
      do: {:ok, %{status: 200, headers: %{}, body: :erlang.term_to_binary({method, url, opts})}}
  end

  setup do
    on_exit(fn -> Application.delete_env(:kiln_plugin, :safe_fetch) end)
  end

  defp echoed({:ok, %{body: body}}), do: :erlang.binary_to_term(body)

  test "with no core and nothing configured, every call is an error" do
    refute Code.ensure_loaded?(KilnCMS.SafeFetch)
    assert {:error, reason} = Kiln.SafeFetch.get("https://example.com/")
    assert reason =~ "KilnCMS is not loaded"
  end

  test "a configured implementation receives the method, URL and accepted options" do
    Application.put_env(:kiln_plugin, :safe_fetch, Echo)

    assert {:get, "https://example.com/", [max_bytes: 10]} =
             echoed(Kiln.SafeFetch.get("https://example.com/", max_bytes: 10))

    assert {:post, "https://example.com/", [body: "x"]} =
             echoed(Kiln.SafeFetch.post("https://example.com/", "x"))

    assert {:head, _url, []} = echoed(Kiln.SafeFetch.head("https://example.com/"))
    assert {:delete, _url, []} = echoed(Kiln.SafeFetch.request(:delete, "https://example.com/"))
  end

  test "options outside the documented set never reach the implementation" do
    Application.put_env(:kiln_plugin, :safe_fetch, Echo)

    assert {:get, _url, opts} =
             echoed(
               Kiln.SafeFetch.get("https://example.com/",
                 headers: [{"accept", "application/rss+xml"}],
                 req_options: [connect_options: [transport_opts: [verify: :verify_none]]],
                 max_redirects: 2,
                 anything: true
               )
             )

    assert Enum.sort(Keyword.keys(opts)) == [:headers, :max_redirects]
  end

  test "an unknown method or a non-string URL is an error before any dispatch" do
    Application.put_env(:kiln_plugin, :safe_fetch, Echo)

    assert {:error, "unsupported method: :connect"} =
             Kiln.SafeFetch.request(:connect, "https://example.com/")

    assert {:error, _reason} = Kiln.SafeFetch.get(nil)
  end
end
