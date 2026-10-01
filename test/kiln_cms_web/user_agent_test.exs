defmodule KilnCMSWeb.UserAgentTest do
  use ExUnit.Case, async: true

  alias KilnCMSWeb.UserAgent

  doctest KilnCMSWeb.UserAgent

  # Each agent names several engines for compatibility, so the order of the
  # checks is the whole parser; these are the cases that order exists for.
  for {ua, browser, platform} <- [
        {"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36 Edg/125.0.0.0",
         "Edge", "Windows"},
        {"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
         "Chrome", "Windows"},
        {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
         "Safari", "macOS"},
        {"Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/125.0 Mobile/15E148 Safari/604.1",
         "Chrome", "iOS"},
        {"Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
         "Safari", "iOS"},
        {"Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36",
         "Chrome", "Android"},
        {"Mozilla/5.0 (X11; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0", "Firefox",
         "Linux"},
        {"Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
         "Chrome", "ChromeOS"},
        {"curl/8.6.0", nil, nil}
      ] do
    test "#{inspect(browser)} on #{inspect(platform)}: #{String.slice(ua, 0, 48)}" do
      assert UserAgent.parse(unquote(ua)) ==
               %{browser: unquote(browser), platform: unquote(platform)}
    end
  end

  test "an oversized header is bounded rather than scanned whole" do
    assert %{browser: nil, platform: nil} = UserAgent.parse(String.duplicate("x", 100_000))
  end
end
