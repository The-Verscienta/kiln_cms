defmodule KilnCMSWeb.UrlRedactionTest do
  @moduledoc """
  Credentials taken out of URLs, query strings and inspected terms before
  they reach a trace or an error report.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.UrlRedaction

  @secret "T0kenSecretValue123"

  describe "path/1" do
    test "a token route's secret segment is filtered, an ordinary path kept" do
      assert UrlRedaction.path("/magic_link/#{@secret}") == "/magic_link/[FILTERED]"
      assert UrlRedaction.path("/fr/password-reset/#{@secret}") == "/fr/password-reset/[FILTERED]"
      assert UrlRedaction.path("/blog/hello-world") == "/blog/hello-world"
    end

    test "an encoded segment is decoded before it is matched" do
      assert UrlRedaction.path("/magic%5Flink/#{@secret}") == "/magic%5Flink/[FILTERED]"
    end

    test "a query on the path is masked too" do
      assert UrlRedaction.path("/blog/x?preview_token=#{@secret}&page=2") ==
               "/blog/x?preview_token=[FILTERED]&page=2"
    end
  end

  describe "query_string/1" do
    test "credential parameters are masked, the rest kept byte for byte" do
      query = "a=1&preview_token=#{@secret}&unlock=#{@secret}&api_key=#{@secret}&q=x+y%20z"

      assert UrlRedaction.query_string(query) ==
               "a=1&preview_token=[FILTERED]&unlock=[FILTERED]&api_key=[FILTERED]&q=x+y%20z"
    end

    test "an encoded or upper-case credential key is caught" do
      assert UrlRedaction.query_string("preview%5Ftoken=#{@secret}") ==
               "preview%5Ftoken=[FILTERED]"

      assert UrlRedaction.query_string("TOKEN=#{@secret}") == "TOKEN=[FILTERED]"
    end

    test "an empty query stays empty" do
      assert UrlRedaction.query_string("") == ""
    end
  end

  describe "url/1" do
    test "path, query and userinfo are all redacted" do
      url = "https://user:pw@example.com/magic_link/#{@secret}?token=#{@secret}&a=b"
      redacted = UrlRedaction.url(url)

      refute redacted =~ @secret
      refute redacted =~ "pw@"
      assert redacted =~ "a=b"
      assert redacted =~ "example.com"
    end

    test "a websocket URL's token is masked" do
      assert UrlRedaction.url("wss://example.com/ws/collab/websocket?token=#{@secret}&vsn=2.0.0") ==
               "wss://example.com/ws/collab/websocket?token=[FILTERED]&vsn=2.0.0"
    end

    test "a URL with nothing to redact is returned exactly as given" do
      for url <- ["https://example.com:443/blog?", "https://example.com/blog/a%20b", "/blog"] do
        assert UrlRedaction.url(url) == url
      end
    end
  end

  describe "text/1" do
    test "an inspected LiveView state loses its join URL, path, query and token assigns" do
      state =
        inspect(%{
          socket: %{
            host_uri: %URI{
              scheme: "https",
              host: "example.com",
              path: "/auth/invite/#{@secret}",
              query: "preview_token=#{@secret}"
            },
            assigns: %{token: @secret, invite_token: @secret, title: "Join"}
          },
          url: "https://example.com/password-reset/#{@secret}",
          params: %{"token" => @secret, "page" => "2"}
        })

      assert state =~ @secret
      redacted = UrlRedaction.text(state)

      refute redacted =~ @secret
      assert redacted =~ ~s(title: "Join")
      assert redacted =~ ~s("page" => "2")
      assert redacted =~ "/auth/invite/[FILTERED]"
    end

    test "an unquoted URL in a log line is redacted" do
      assert UrlRedaction.text("joined https://example.com/magic_link/#{@secret} ok") ==
               "joined https://example.com/magic_link/[FILTERED] ok"
    end

    test "text with nothing in it is unchanged" do
      text = ~s(%{count: 3, "name" => "x", path: "/blog/a"})
      assert UrlRedaction.text(text) == text
    end
  end
end
