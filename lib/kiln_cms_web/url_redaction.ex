defmodule KilnCMSWeb.UrlRedaction do
  @moduledoc """
  Takes credentials out of a URL, a query string, or a block of text that
  quotes URLs, before it leaves the app as a trace attribute or an error
  report.

  It is `KilnCMSWeb.RequestRedaction` (which secret path segments a route
  has) plus the query rule of `KilnCMSWeb.SentryScrubber.sensitive_key?/1`
  (which parameter names are credentials), applied to strings:

    * `path/1` — an encoded request path; a `?query` on it is masked too.
    * `query_string/1` — a raw query string: a credential parameter's value becomes
      `[FILTERED]`, every other pair is kept as written.
    * `url/1` — an absolute or relative URL: its path, query and userinfo.
    * `text/1` — free text such as an inspected process state: every URL in
      it, every quoted path or query, and every quoted value under a
      credential-named key (`token: "…"`, `"token" => "…"`).

  Nothing here raises. A value that cannot be redacted is replaced whole
  with `[FILTERED]`.
  """

  alias KilnCMSWeb.RequestRedaction
  alias KilnCMSWeb.SentryScrubber

  @filtered "[FILTERED]"

  @doc "The placeholder a redacted value is replaced with."
  @spec filtered() :: String.t()
  def filtered, do: @filtered

  @doc """
  Redact an encoded request path (and its query, if it carries one).
  """
  @spec path(String.t()) :: String.t()
  def path(path) when is_binary(path) do
    case String.split(path, "?", parts: 2) do
      [path] -> RequestRedaction.redact_encoded_path(path)
      [path, query] -> RequestRedaction.redact_encoded_path(path) <> "?" <> query_string(query)
    end
  rescue
    _error -> @filtered
  end

  @doc """
  Mask the value of every credential parameter in a raw query string. Other
  pairs, and the order, are kept byte for byte.
  """
  @spec query_string(String.t()) :: String.t()
  def query_string(""), do: ""

  def query_string(query) when is_binary(query) do
    query
    |> String.split("&")
    |> Enum.map_join("&", &redact_pair/1)
  rescue
    _error -> @filtered
  end

  defp redact_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, _value] -> if credential?(key), do: key <> "=" <> @filtered, else: pair
      [key] -> if credential?(key), do: @filtered, else: pair
    end
  end

  defp credential?(key) do
    key |> decode_component() |> SentryScrubber.sensitive_key?()
  end

  # `+` is a space in a form-encoded key; a malformed escape is compared as
  # written.
  defp decode_component(component) do
    URI.decode_www_form(component)
  rescue
    ArgumentError -> component
  end

  @doc """
  Redact a URL: the secret segments of its path, the credential parameters of
  its query, and any userinfo. A relative URL (`/path?query`) works too.
  """
  @spec url(String.t()) :: String.t()
  def url(url) when is_binary(url) do
    uri = URI.parse(url)

    %{
      uri
      | path: uri.path && RequestRedaction.redact_encoded_path(uri.path),
        query: uri.query && query_string(uri.query),
        userinfo: uri.userinfo && @filtered
    }
    |> URI.to_string()
    |> keep_unchanged(url, uri)
  rescue
    _error -> @filtered
  end

  # `URI.to_string/1` normalizes what it rebuilds (a default port, an empty
  # query). A URL with nothing to redact is returned exactly as given.
  defp keep_unchanged(rebuilt, original, uri) do
    if rebuilt == URI.to_string(uri), do: original, else: rebuilt
  end

  # A URL with a scheme, anywhere in the text, up to whitespace, a quote or an
  # angle bracket.
  @url_in_text ~r{\b[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s"'<>]+}
  # A double-quoted string as `inspect/1` writes one.
  @quoted ~r{"((?:[^"\\]|\\.)*)"}
  @credential_name "[A-Za-z0-9_\\-]*(?:token|secret|password|passphrase|authorization|api_key|apikey|unlock)[A-Za-z0-9_\\-]*"
  # `token: "…"`, as an atom key in an inspected map, struct or keyword list.
  @atom_key_value Regex.compile!(~s/\\b(#{@credential_name}): #{@quoted.source}/, "i")
  # `"token" => "…"`, as a string key in an inspected map.
  @string_key_value Regex.compile!(~s/("#{@credential_name}") => #{@quoted.source}/, "i")
  @query_like ~r/\A[^\s=&\/?]+=[^\s]*\z/

  @doc """
  Redact every credential `text` quotes: URLs (with or without quotes),
  quoted paths and query strings, and quoted values under a credential-named
  key. Meant for inspected terms such as a crashed process's state and last
  message, which hold a LiveView's join URL and its assigns.
  """
  @spec text(String.t()) :: String.t()
  def text(text) when is_binary(text) do
    text
    |> then(&Regex.replace(@url_in_text, &1, fn url -> url(url) end))
    |> then(&Regex.replace(@quoted, &1, fn whole, inner -> quoted(whole, inner) end))
    |> then(&Regex.replace(@atom_key_value, &1, "\\1: \"#{@filtered}\""))
    |> then(&Regex.replace(@string_key_value, &1, "\\1 => \"#{@filtered}\""))
  rescue
    _error -> @filtered
  end

  defp quoted(whole, inner) do
    cond do
      String.starts_with?(inner, "/") -> ~s("#{path(inner)}")
      Regex.match?(@query_like, inner) -> ~s("#{query_string(inner)}")
      true -> whole
    end
  end
end
