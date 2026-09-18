defmodule KilnCMS.Config.ProdForceSslTest do
  @moduledoc """
  Pins which requests `config/prod.exs`'s `force_ssl` lets through over plain
  HTTP (#1529).

  `force_ssl` is compile-time and only set in prod, so the test suite's
  endpoint never runs `Plug.SSL` at all. This reads the real prod config and
  runs `Plug.SSL` with exactly those options, so an edit to the exclude list
  is what gets tested — not a copy of it.

  The shape being protected: a PaaS health checker probes the container by its
  internal address, over HTTP, with no `X-Forwarded-Proto`. A 301 there reads
  as an unhealthy deploy on every platform that counts only 2xx, so a
  one-click deploy never goes live.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  setup_all do
    opts =
      "config/prod.exs"
      |> Config.Reader.read!(env: :prod)
      |> get_in([:kiln_cms, KilnCMSWeb.Endpoint, :force_ssl])

    {:ok, ssl: Plug.SSL.init(opts)}
  end

  defp probe(ssl, url, headers \\ []) do
    conn =
      Enum.reduce(headers, conn(:get, url), fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)

    Plug.SSL.call(conn, ssl)
  end

  defp redirected?(conn), do: conn.halted and conn.status == 301

  test "a platform health check on /live or /up is not redirected", %{ssl: ssl} do
    # An internal address, as Render/Railway/Fly/DigitalOcean probe with.
    for path <- ~w(/live /up) do
      refute redirected?(probe(ssl, "http://10.0.4.17:4000" <> path)),
             "#{path} over plain HTTP was redirected — a PaaS health check would fail"
    end
  end

  test "the image's own HEALTHCHECK host is still excluded", %{ssl: ssl} do
    refute redirected?(probe(ssl, "http://127.0.0.1:4000/ready"))
  end

  test "/ready is not excluded — its payload stays behind HTTPS", %{ssl: ssl} do
    assert redirected?(probe(ssl, "http://10.0.4.17:4000/ready"))
  end

  test "an ordinary page over plain HTTP is still redirected", %{ssl: ssl} do
    # The exclusion is exact-path: it must not open the site, or a path that
    # merely starts with a probe's name, to plain HTTP.
    for path <- ~w(/ /editor /upload /live/x /up/anything) do
      assert redirected?(probe(ssl, "http://cms.example.com" <> path)),
             "#{path} over plain HTTP was served instead of redirected"
    end
  end

  test "a request the proxy marks as https is served, with HSTS", %{ssl: ssl} do
    conn = probe(ssl, "http://cms.example.com/", [{"x-forwarded-proto", "https"}])

    refute conn.halted
    assert [_hsts] = Plug.Conn.get_resp_header(conn, "strict-transport-security")
  end
end
