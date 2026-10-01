defmodule KilnCMSWeb.UserAgent do
  @moduledoc """
  A browser's user-agent string, reduced to two coarse names — `"Firefox"`,
  `"macOS"` — for the session list on the settings page (#1823).

  Only the families are kept, never versions or the string itself: enough to
  tell "the laptop" from "the phone", and nothing a fingerprint needs. Unknown
  agents give `nil`, which the page shows as an unknown browser.

  Order matters below. Most agents name several engines for compatibility —
  Edge says "Chrome" and "Safari", Chrome says "Safari", every iPhone browser
  says "Safari" — so the more specific family is tested first.
  """

  @browsers [
    {~r/\bEdg(e|A|iOS)?\//, "Edge"},
    {~r/\b(OPR|Opera)\//, "Opera"},
    {~r/\bSamsungBrowser\//, "Samsung Internet"},
    {~r/\bVivaldi\//, "Vivaldi"},
    {~r/\b(Firefox|FxiOS)\//, "Firefox"},
    {~r/\b(Chrome|CriOS|Chromium)\//, "Chrome"},
    {~r/\bVersion\/[\d.]+.*\bSafari\//, "Safari"}
  ]

  @platforms [
    {~r/\b(iPhone|iPad|iPod)\b/, "iOS"},
    {~r/\bAndroid\b/, "Android"},
    {~r/\bCrOS\b/, "ChromeOS"},
    {~r/\bWindows\b/, "Windows"},
    {~r/\bMac OS X\b|\bMacintosh\b/, "macOS"},
    {~r/\bLinux\b/, "Linux"}
  ]

  @doc """
  `%{browser: name | nil, platform: name | nil}` for a user-agent string.

      iex> KilnCMSWeb.UserAgent.parse("Mozilla/5.0 (Macintosh; Intel Mac OS X 14.4; rv:126.0) Gecko/20100101 Firefox/126.0")
      %{browser: "Firefox", platform: "macOS"}

      iex> KilnCMSWeb.UserAgent.parse(nil)
      %{browser: nil, platform: nil}
  """
  @spec parse(String.t() | nil) :: %{browser: String.t() | nil, platform: String.t() | nil}
  def parse(user_agent) when is_binary(user_agent) do
    # Real agents are a few hundred bytes; the cap only bounds the regex work
    # on a hostile header.
    ua = binary_part(user_agent, 0, min(byte_size(user_agent), 512))
    %{browser: first_match(@browsers, ua), platform: first_match(@platforms, ua)}
  end

  def parse(_user_agent), do: %{browser: nil, platform: nil}

  defp first_match(families, ua) do
    Enum.find_value(families, fn {pattern, name} -> if Regex.match?(pattern, ua), do: name end)
  end
end
