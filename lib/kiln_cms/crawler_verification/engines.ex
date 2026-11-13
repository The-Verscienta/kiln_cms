defmodule KilnCMS.CrawlerVerification.Engines do
  @moduledoc """
  The reverse-DNS domains each search engine publishes for its crawlers
  (#2254), the published IP range list each one offers (#2586), and the
  hostname rules a PTR answer is read under.

  One row per engine `KilnCMS.BotClass.search_engine/1` can name; a test
  checks that every engine has one.

  | Engine        | A crawler's PTR name ends in                 | Source |
  | ------------- | -------------------------------------------- | ------ |
  | `:google`     | `googlebot.com`                              | <https://developers.google.com/crawling/docs/crawlers-fetchers/verify-google-requests> |
  | `:bing`       | `search.msn.com`                             | <https://blogs.bing.com/webmaster/2012/8/How-to-Verify-that-Bingbot-is-Bingbot/> |
  | `:apple`      | `applebot.apple.com`                         | <https://support.apple.com/en-us/119829> |
  | `:yandex`     | `yandex.ru`, `yandex.net`, `yandex.com`      | <https://yandex.com/support/webmaster/en/robot-workings/check-yandex-robots.html> |
  | `:baidu`      | `baidu.com`, `baidu.jp`                      | <https://help.baidu.com/question?prod_id=99&class=0&id=3001> |
  | `:duckduckgo` | none: DuckDuckBot publishes IP ranges only   | <https://duckduckgo.com/duckduckgo-help-pages/results/duckduckbot> |

  ## Published IP ranges

  The lists `KilnCMS.CrawlerVerification.Ranges` fetches, each the vendor's
  own published list of its crawlers' addresses. Yandex and Baidu publish
  none and are checked by DNS only.

  | Engine        | Published list |
  | ------------- | -------------- |
  | `:google`     | <https://developers.google.com/static/crawling/ipranges/common-crawlers.json> |
  | `:bing`       | <https://www.bing.com/toolbox/bingbot.json> |
  | `:apple`      | <https://search.developer.apple.com/applebot.json> |
  | `:duckduckgo` | <https://duckduckgo.com/duckduckbot.json> |

  `config :kiln_cms, KilnCMS.CrawlerVerification.Ranges, sources: %{engine =>
  url | false}` overrides a source per engine: an engine the map leaves out
  keeps its default, and `false` drops that engine's list.

  Google's own list also names `googleusercontent.com` and `google.com`, but
  those carry Google's user-triggered fetchers and other products, not the
  common crawlers `BotClass` names (and `googleusercontent.com` is any Google
  Cloud customer's reverse DNS). They are deliberately absent.

  ## Matching

  A name matches a suffix when it **is** the suffix or ends in `"." <> suffix`,
  so `evilgooglebot.com` and `googlebot.com.evil.net` do not match
  `googlebot.com`. A name is lowercased and loses one trailing dot first, and
  only a plain hostname is read at all: ASCII letters, digits, `-` and `_`
  in dot-separated labels of 1 to 63 bytes, 253 in all. A PTR answer whose
  label holds an escaped dot (`crawl\\.googlebot\\.com`, one label) is not a
  hostname and matches nothing.
  """

  alias KilnCMS.BotClass

  @suffixes %{
    google: ["googlebot.com"],
    bing: ["search.msn.com"],
    apple: ["applebot.apple.com"],
    yandex: ["yandex.ru", "yandex.net", "yandex.com"],
    baidu: ["baidu.com", "baidu.jp"],
    duckduckgo: :none
  }

  @range_sources %{
    google: "https://developers.google.com/static/crawling/ipranges/common-crawlers.json",
    bing: "https://www.bing.com/toolbox/bingbot.json",
    apple: "https://search.developer.apple.com/applebot.json",
    duckduckgo: "https://duckduckgo.com/duckduckbot.json"
  }

  @label ~r/\A[a-z0-9_-]{1,63}\z/

  @doc "Every engine with a row, in `BotClass.engines/0` order."
  @spec engines() :: [BotClass.engine()]
  def engines, do: Enum.filter(BotClass.engines(), &Map.has_key?(@suffixes, &1))

  @doc """
  The PTR suffixes for `engine`, or `:none` when it cannot be verified by
  reverse DNS (DuckDuckBot) or is not an engine at all.
  """
  @spec suffixes(atom()) :: [String.t()] | :none
  def suffixes(engine), do: Map.get(@suffixes, engine, :none)

  @doc """
  Can `engine` be verified by reverse DNS? Says nothing about a published
  range list (`range_source/1`): DuckDuckBot is not verifiable here, yet an
  address in its list is verified.
  """
  @spec verifiable?(atom()) :: boolean()
  def verifiable?(engine), do: suffixes(engine) != :none

  @doc "Does `engine` have a row at all?"
  @spec known?(atom()) :: boolean()
  def known?(engine), do: Map.has_key?(@suffixes, engine)

  @doc """
  The HTTPS URL of `engine`'s published crawler range list, or `nil` when it
  publishes none or the operator turned it off. The operator's `:sources`
  map overrides one engine at a time (see the moduledoc).
  """
  @spec range_source(atom()) :: String.t() | nil
  def range_source(engine) do
    overrides = Map.new(ranges_config()[:sources] || %{})

    case Map.fetch(overrides, engine) do
      {:ok, url} when is_binary(url) -> if known?(engine), do: url
      {:ok, _off} -> nil
      :error -> Map.get(@range_sources, engine)
    end
  end

  @doc "The engines with a range list to fetch, in `engines/0` order."
  @spec range_engines() :: [BotClass.engine()]
  def range_engines, do: Enum.filter(engines(), &range_source/1)

  @doc "The built-in range list URLs, before any override."
  @spec default_range_sources() :: %{BotClass.engine() => String.t()}
  def default_range_sources, do: @range_sources

  defp ranges_config, do: Application.get_env(:kiln_cms, KilnCMS.CrawlerVerification.Ranges, [])

  @doc """
  A PTR answer as a comparable hostname: lowercased, one trailing dot dropped.
  `nil` for anything that is not a plain hostname (see the moduledoc).

      iex> KilnCMS.CrawlerVerification.Engines.normalize_host(~c"CRAWL-1.GoogleBot.com.")
      "crawl-1.googlebot.com"

      iex> KilnCMS.CrawlerVerification.Engines.normalize_host("crawl\\\\.googlebot\\\\.com")
      nil
  """
  @spec normalize_host(String.t() | charlist()) :: String.t() | nil
  def normalize_host(name) when is_list(name) do
    name |> List.to_string() |> normalize_host()
  rescue
    # A charlist that is not a valid string (a byte above 255 is not a name).
    ArgumentError -> nil
  end

  def normalize_host(name) when is_binary(name) do
    host = name |> String.downcase(:ascii) |> String.replace_suffix(".", "")

    if byte_size(host) in 1..253 and Enum.all?(String.split(host, "."), &(&1 =~ @label)),
      do: host,
      else: nil
  end

  def normalize_host(_), do: nil

  @doc "Does the normalized `host` fall under one of `engine`'s suffixes?"
  @spec matches?(atom(), String.t()) :: boolean()
  def matches?(engine, host) when is_binary(host) do
    case suffixes(engine) do
      :none -> false
      suffixes -> Enum.any?(suffixes, &under?(host, &1))
    end
  end

  @doc "The verifiable engines whose suffixes the normalized `host` falls under."
  @spec engines_for(String.t()) :: [BotClass.engine()]
  def engines_for(host) when is_binary(host), do: Enum.filter(engines(), &matches?(&1, host))

  defp under?(host, suffix), do: host == suffix or String.ends_with?(host, "." <> suffix)
end
