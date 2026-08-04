defmodule KilnCMSWeb.ReferrerSourceTest do
  @moduledoc """
  Table-driven coverage of the referrer classifier (#619): never a host or
  URL out, only one of five coarse categories.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.ReferrerSource

  @host "example.com"

  describe "classify/2 — direct" do
    test "a nil header is direct" do
      assert ReferrerSource.classify(nil, @host) == :direct
    end

    test "an empty header is direct" do
      assert ReferrerSource.classify("", @host) == :direct
    end

    test "a header that fails to parse a host is direct" do
      for garbage <- ["not a url", "://", "   ", "javascript:alert(1)"] do
        assert ReferrerSource.classify(garbage, @host) == :direct,
               "expected #{inspect(garbage)} to classify as :direct"
      end
    end
  end

  describe "classify/2 — internal" do
    test "same host as the request, any scheme/path/query" do
      for referer <- [
            "https://example.com/",
            "http://example.com/blog/post-1",
            "https://example.com/search?q=thing",
            "https://EXAMPLE.COM/Blog"
          ] do
        assert ReferrerSource.classify(referer, @host) == :internal,
               "expected #{inspect(referer)} to classify as :internal"
      end
    end

    test "a different host is not internal" do
      refute ReferrerSource.classify("https://other.example/", @host) == :internal
    end
  end

  describe "classify/2 — search" do
    @search_hosts ~w(
      https://www.google.com/search?q=x
      https://bing.com/
      https://duckduckgo.com/
      https://search.yahoo.com/search
      https://www.yandex.com/
      https://www.baidu.com/s
      https://www.ecosia.org/
      https://search.brave.com/search
    )

    for referer <- @search_hosts do
      test "#{referer} classifies as :search" do
        assert ReferrerSource.classify(unquote(referer), @host) == :search
      end
    end

    test "a subdomain of a known search host matches without its own list entry" do
      assert ReferrerSource.classify("https://news.google.com/", @host) == :search
      assert ReferrerSource.classify("https://de.search.yahoo.com/", @host) == :search
    end

    test "a Google country-code domain matches (a different registrable domain, not a subdomain)" do
      assert ReferrerSource.classify("https://www.google.co.uk/", @host) == :search
      assert ReferrerSource.classify("https://www.google.de/search?q=x", @host) == :search
    end
  end

  describe "classify/2 — social" do
    @social_hosts ~w(
      https://www.facebook.com/
      https://t.co/abc123
      https://x.com/someone/status/1
      https://www.linkedin.com/feed
      https://www.instagram.com/
      https://old.reddit.com/r/programming
      https://news.ycombinator.com/item?id=1
      https://bsky.app/profile/someone
    )

    for referer <- @social_hosts do
      test "#{referer} classifies as :social" do
        assert ReferrerSource.classify(unquote(referer), @host) == :social
      end
    end
  end

  describe "classify/2 — other" do
    test "an unrecognized host classifies as :other" do
      assert ReferrerSource.classify("https://a-random-blog.example/post", @host) == :other
    end

    test "the unrecognized host itself is never present in the result" do
      # The contract isn't just "returns :other" — nothing about the returned
      # atom or any side channel can reconstruct the original host.
      result = ReferrerSource.classify("https://intranet.megacorp.internal/wiki/x", @host)
      assert result == :other
      refute is_binary(result)
    end

    test "a host that merely embeds a known name, fore or aft, does not match it" do
      # Regression pin for the subdomain-suffix matching added alongside the
      # ccTLD entries: `.` must prefix the suffix, or `google.com.attacker.net`
      # (contains "google.com" as a substring, but is not a subdomain of it)
      # would falsely classify as :search.
      assert ReferrerSource.classify("https://google.com.attacker.net/", @host) == :other
      assert ReferrerSource.classify("https://evil-google.com/", @host) == :other
      assert ReferrerSource.classify("https://facebook.com.evil.example/", @host) == :other
    end
  end

  describe "classify/2 — the query string and path never survive" do
    test "UTM parameters on an internal referrer don't change the outcome" do
      assert ReferrerSource.classify(
               "https://example.com/blog?utm_source=newsletter&utm_campaign=x",
               @host
             ) == :internal
    end

    test "a path or query that looks like PII on an unrecognized host still only yields :other" do
      assert ReferrerSource.classify(
               "https://mail.example.net/inbox?token=super-secret-session-abc123",
               @host
             ) == :other
    end
  end
end
