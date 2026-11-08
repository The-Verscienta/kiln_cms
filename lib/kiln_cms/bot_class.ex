defmodule KilnCMS.BotClass do
  @moduledoc """
  Which kind of client a request's `User-Agent` says it is (#2243), for the
  per-class ceilings inside the `:delivery` rate-limit bucket
  (`KilnCMS.BotBudgets`, `KilnCMSWeb.Plugs.RateLimit`).

  Five classes: `:search_engine`, `:ai_crawler`, `:declared_bot`, `:empty` and
  `:browser`. This is **cost control, not security**: a user agent is whatever
  the client typed, so anyone can claim to be Googlebot or a browser. Nothing
  here grants access, and a higher ceiling for a class is a higher ceiling for
  anyone who spoofs it. Verifying a crawler by reverse DNS is #2254.

  ## The order

  The first stage that matches decides:

    1. **AI crawler** names (`GPTBot`, `ClaudeBot`, `CCBot`, …) → `:ai_crawler`.
    2. **Search engine** names (`Googlebot`, `bingbot`, `DuckDuckBot`, …) →
       `:search_engine`.
    3. A user agent that matched **both** 1 and 2 is `:declared_bot`: it claims
       two things at once, so it gets neither class's ceiling.
    4. **Scripting libraries and headless browsers** (`curl/`, `python-requests/`,
       `HeadlessChrome`, …) and the curated link-preview fetchers
       (`facebookexternalhit`, `Twitterbot`, `Slackbot`, …) → `:declared_bot`.
    5. **Browser-shaped** (`Mozilla/5.0 (` with `AppleWebKit/`, `Gecko/` or
       `Trident/`) → `:browser`.
    6. A generic **product token ending in bot, crawler, spider or scraper**,
       followed by `/`, `;`, `)`, `+` or the end → `:declared_bot`. Not applied
       to a browser-shaped user agent (stage 5 has already answered), so a
       phone model or an app name inside a real browser's string cannot demote
       it.
    7. **Anything else that is not empty** → `:browser`. Media players
       (`AppleCoreMedia`, `stagefright`, `ExoPlayerLib`, VLC, Roku), native
       HTTP stacks (`CFNetwork`, `Dalvik`, `okhttp`) and old or unusual browsers
       land here, because an unknown client is far more often a person's device
       than a scraper, and a scraper that wants to look like a browser can.

  A missing, empty or all-whitespace user agent is `:empty`.

  Matching is case-insensitive and byte-oriented (no `u` flag), so invalid
  UTF-8 cannot raise, and only the first 512 bytes are looked at.

  ## Tokens that never reach this

  `Google-Extended` and `Applebot-Extended` are robots.txt product tokens only:
  Google and Apple crawl with their ordinary user agents and read those tokens
  to decide what the content may be used for. No request carries them, so
  there is nothing to classify; control them in robots.txt.

  ## Adding a name

  The lists are curated here, not configured: what an operator configures is
  each class's ceiling, never its membership. Adding a token is a code change
  with a test row in `test/kiln_cms/bot_class_test.exs`.
  """

  @type t :: :search_engine | :ai_crawler | :declared_bot | :empty | :browser

  @classes [:browser, :search_engine, :ai_crawler, :declared_bot, :empty]

  # Only this much of a user agent is matched. Real ones are well under 300
  # bytes; the cap bounds the regex work a 10 KB header could ask for.
  @max_bytes 512

  # One compiled regex per stage, held in module attributes so each match runs
  # the precompiled pattern. No `u` flag anywhere: matching is over bytes, so a
  # header that is not valid UTF-8 matches nothing rather than raising.
  @ai_crawler ~r/\b(?:GPTBot|ChatGPT-User|OAI-SearchBot|ClaudeBot|Claude-User|Claude-SearchBot|anthropic-ai|CCBot|PerplexityBot|Perplexity-User|Bytespider|Amazonbot|meta-externalagent)\b/i

  # `Googlebot` also covers `Googlebot-Image`, `-News` and `-Video` (the hyphen
  # is a word boundary).
  @search_engine ~r/\b(?:Googlebot|Google-InspectionTool|bingbot|DuckDuckBot|Baiduspider|YandexBot|Applebot)\b/i

  # Scripting tools, headless browsers, and named fetchers that do not need the
  # generic token to be caught (some send a browser-shaped string). `okhttp` is
  # deliberately absent: it is the HTTP stack of native Android apps, which
  # play `/media/:id/stream` for a person.
  @declared ~r/(?:(?<![a-z0-9_.\-])(?:curl|Wget|python-requests|Python-urllib|python-httpx|aiohttp|Go-http-client|Java|libwww-perl|Scrapy|axios|node-fetch|PostmanRuntime|Apache-HttpClient|req)\/|\b(?:HeadlessChrome|PhantomJS|facebookexternalhit|Twitterbot|Slackbot|LinkedInBot|Discordbot|PetalBot|AhrefsBot|SemrushBot)\b)/i

  @browser_shaped ~r/\AMozilla\/5\.0 \(.*(?:AppleWebKit\/|Gecko\/|Trident\/)/i

  # A product token that ends in bot/crawler/spider/scraper, starting at the
  # start of the string or after a space, `(`, `;` or `+`, and followed by `/`,
  # `;`, `)`, `+` or the end. The terminators are what keep a phone model
  # ("CUBOT P80") and a version suffix ("-bot7") out.
  @generic_bot ~r/(?:\A|[\s(;+])[a-z0-9._\-]*(?:bot|crawler|spider|scraper)(?:[\/;)+]|\z)/i

  @doc "Every class `classify/1` can answer, browser first."
  @spec classes() :: [t()]
  def classes, do: @classes

  @doc """
  The class of a `User-Agent` value. Anything that is not a binary, and any
  binary that is empty or only whitespace, is `:empty`.
  """
  @spec classify(term()) :: t()
  def classify(user_agent) when is_binary(user_agent) do
    case user_agent |> truncate() |> String.trim() do
      "" -> :empty
      ua -> classify_present(ua)
    end
  end

  def classify(_not_a_binary), do: :empty

  defp classify_present(ua) do
    case {Regex.match?(@ai_crawler, ua), Regex.match?(@search_engine, ua)} do
      {true, true} -> :declared_bot
      {true, false} -> :ai_crawler
      {false, true} -> :search_engine
      {false, false} -> classify_unnamed(ua)
    end
  end

  defp classify_unnamed(ua) do
    cond do
      Regex.match?(@declared, ua) -> :declared_bot
      Regex.match?(@browser_shaped, ua) -> :browser
      Regex.match?(@generic_bot, ua) -> :declared_bot
      true -> :browser
    end
  end

  defp truncate(ua) when byte_size(ua) > @max_bytes, do: binary_part(ua, 0, @max_bytes)
  defp truncate(ua), do: ua
end
