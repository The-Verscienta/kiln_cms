defmodule KilnCMSWeb.ReferrerSource do
  @moduledoc """
  Classifies the `referer` request header into a small, privacy-safe category
  — never a host or URL (#619, phase 2 of `docs/advanced-analytics-plan.md`).

  Deliberately in the **web** namespace rather than under `KilnCMS.Analytics`:
  the raw header exists only here, and this module's public API is the
  boundary that keeps it from traveling any further. `KilnCMS.Analytics`
  never sees anything but the classified atom.

  `:direct` is a catch-all, not just "typed the URL": browsers now default to
  `strict-origin-when-cross-origin`, so a referring site's own choice to
  suppress its header (or the header simply being absent) is indistinguishable
  from direct traffic here. Say so wherever this classification reaches a UI.
  """

  @type source :: :direct | :internal | :search | :social | :other

  # Curated, compile-time, host-only. Never widened by config — a config-added
  # host would be an operator adding a value straight to the classifier's
  # output without a code review, and the built-in/config split precedent in
  # this codebase (`KilnCMS.OEmbed.Provider`) is deliberately the same: config
  # may narrow a built-in list, never extend it with a new host.
  #
  # Matching (see `known_match?/2`) is exact-or-subdomain: `news.google.com`
  # and `de.search.yahoo.com` match `google.com`/`yahoo.com` without a
  # separate entry, but `google.com.attacker.net` and `evil-google.com` do
  # not — neither ends with `.google.com`. Google's per-country domains are
  # a *different* registrable domain, not a subdomain, so those still need
  # their own entries — listed below for the highest-traffic ccTLDs; a
  # smaller one falling through to `:other` is the accepted long-tail cost
  # (same as any Mastodon instance beyond the flagship).
  @known_search ~w(
    google.com google.co.uk google.de google.fr google.ca google.com.au
    google.co.jp google.co.in google.com.br google.es google.it google.nl
    google.ru google.co.kr google.com.mx google.co.id
    bing.com
    duckduckgo.com
    yahoo.com
    yandex.com
    baidu.com
    ecosia.org
    brave.com
    startpage.com
    marginalia.nu
  )

  @known_social ~w(
    facebook.com
    twitter.com x.com t.co
    linkedin.com lnkd.in
    instagram.com
    reddit.com
    pinterest.com
    news.ycombinator.com
    mastodon.social bsky.app
    threads.net
    tiktok.com
    youtube.com youtu.be
    discord.com
  )

  @doc """
  Classifies a `referer` header value against the current request's own
  `host`.

  1. Absent or empty header → `:direct`.
  2. `URI.parse/1`, keeping **only the host** — scheme, port, path, query and
     fragment (and anything they might carry: UTM/campaign parameters, PII
     hiding in a query string) are discarded immediately, before this
     function returns anything.
  3. Referrer host equals `host` (case-insensitively) → `:internal`.
  4. Referrer host equals, or is a subdomain of, an entry in the built-in
     search-engine allowlist → `:search`.
  5. Referrer host equals, or is a subdomain of, an entry in the built-in
     social-media allowlist → `:social`.
  6. Anything else → `:other`. The unmatched host is **not** returned or
     stored anywhere — a long-tail host is itself identifying (a private
     intranet, a niche forum, a shared document URL), so only the *fact* of
     an unrecognized referrer survives.

  A malformed `referer` value (fails to parse, or parses with no host) is
  treated the same as an absent one: `:direct`.
  """
  @spec classify(String.t() | nil, String.t()) :: source()
  def classify(referer, host)
  def classify(nil, _host), do: :direct
  def classify("", _host), do: :direct

  def classify(referer, host) when is_binary(referer) and is_binary(host) do
    case referer_host(referer) do
      nil -> :direct
      referer_host -> categorize(referer_host, String.downcase(host))
    end
  end

  defp categorize(referer_host, host) do
    cond do
      referer_host == host -> :internal
      known_match?(referer_host, @known_search) -> :search
      known_match?(referer_host, @known_social) -> :social
      true -> :other
    end
  end

  # Exact match, or a genuine subdomain of a known entry — `.` prefixed, so
  # `google.com.attacker.net` and `evil-google.com` (neither ends with
  # `.google.com`) both correctly miss.
  defp known_match?(host, known) do
    Enum.any?(known, &(host == &1 or String.ends_with?(host, "." <> &1)))
  end

  defp referer_host(referer) do
    case URI.parse(referer) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end
end
