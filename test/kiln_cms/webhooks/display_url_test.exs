defmodule KilnCMS.Webhooks.DisplayUrlTest do
  @moduledoc """
  `KilnCMS.Webhooks.display_url/1` (#2245): how a webhook URL is shown
  everywhere Kiln shows it. An incoming-webhook URL carries its own token.
  """
  use ExUnit.Case, async: true

  import KilnCMS.Webhooks, only: [display_url: 1]

  @cases [
    # A Slack incoming webhook: the token is the path.
    {"https://hooks.slack.com/services/T0001/B0002/XXXXabcd9xQz",
     "https://hooks.slack.com/…/9xQz"},
    # Userinfo is dropped, short path or long.
    {"https://user:pa55word@example.com/hook", "https://example.com"},
    {"https://user:pa55word@example.com/hooks/abcdefghijkl", "https://example.com/…/ijkl"},
    # A token in the query counts towards the length and is elided with it.
    {"https://example.com/hook?token=SECRETtokenValue1234", "https://example.com/…/1234"},
    # A short path or query shows the host alone.
    {"https://example.com/hook", "https://example.com"},
    {"https://example.com/hook?a=1", "https://example.com"},
    {"https://example.com", "https://example.com"},
    # The threshold is 16 characters of path and query.
    {"https://example.com/abcdefghijklmn", "https://example.com"},
    {"https://example.com/abcdefghijklmno", "https://example.com/…/lmno"},
    # A port is kept unless it is the scheme's default.
    {"https://example.com:8443/hook", "https://example.com:8443"},
    {"https://example.com:443/hook", "https://example.com"},
    {"http://example.com:80/hook", "http://example.com"},
    # An IPv6 host keeps its brackets.
    {"http://[2001:db8::1]:8080/hooks/abcdefghijklmnop", "http://[2001:db8::1]:8080/…/mnop"},
    {"https://[2001:db8::1]/hook", "https://[2001:db8::1]"},
    # No scheme or no host: nothing of it is shown.
    {"not a url", "••••"},
    {"/relative/path/abcdefghijklmnop", "••••"},
    {"mailto:someone@example.com", "••••"},
    {"", "••••"},
    {nil, "••••"}
  ]

  test "shows the scheme, host, port and at most the last four of a long path" do
    for {url, shown} <- @cases do
      assert display_url(url) == shown, "#{inspect(url)} showed #{inspect(display_url(url))}"
    end
  end

  test "never shows the userinfo or the middle of the path" do
    shown = display_url("https://user:pa55word@example.com/services/T0SECRET/abcd")

    refute shown =~ "pa55word"
    refute shown =~ "user"
    refute shown =~ "T0SECRET"
  end

  test "is idempotent: a masked value comes back unchanged" do
    for {url, shown} <- @cases do
      assert display_url(shown) == shown, "#{inspect(url)}: #{inspect(display_url(shown))}"
      assert display_url(display_url(url)) == display_url(url)
    end
  end

  test "a masked value's tail may hold a ? or a /" do
    for url <- ["https://example.com/abcdefghijklmn?a=1", "https://example.com/abcdefghijklm/a/"] do
      shown = display_url(url)
      assert String.length(shown) == String.length("https://example.com/…/") + 4
      assert display_url(shown) == shown
    end
  end
end
