defmodule KilnCMS.BotClassTest do
  @moduledoc """
  `KilnCMS.BotClass.classify/1` (#2243), one row per user agent. A row is the
  only way a name joins a list, so each list's members and the stage order are
  pinned here.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.BotClass

  doctest KilnCMS.BotClass

  @browser [
    {"desktop Chrome",
     "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"},
    {"desktop Firefox",
     "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.4; rv:125.0) Gecko/20100101 Firefox/125.0"},
    {"iOS Safari",
     "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"},
    {"Edge",
     "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.2478.51"},
    {"Samsung Internet",
     "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/24.0 Chrome/117.0.0.0 Mobile Safari/537.36"},
    {"a CUBOT phone",
     "Mozilla/5.0 (Linux; Android 9; CUBOT P80 Build/PPR1.180610.011) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"},
    {"a CUBOT phone, underscored",
     "Mozilla/5.0 (Linux; Android 12; CUBOT_X30) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"},
    {"an app token ending in a bot-like version",
     "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 MyApp/2.0.robot3"},
    {"an Android webview",
     "Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36"},
    {"Facebook in-app",
     "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [FBAN/FBIOS;FBAV/460.0.0.36.104;FBBV/580000000]"},
    {"Instagram in-app",
     "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 326.0.3.30.91 (iPhone15,2; iOS 17_4; en_US)"},
    {"TikTok in-app",
     "Mozilla/5.0 (Linux; Android 13; SM-A536B Build/TP1A.220624.014; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36 trill_330004 BytedanceWebview/d8a21c6"},
    {"Yandex Browser",
     "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 YaBrowser/24.4.0.0 Safari/537.36"},
    {"the DuckDuckGo browser (not DuckDuckBot)",
     "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 DuckDuckGo/7 Safari/605.1.15"},
    {"Opera Mini (Presto)",
     "Opera/9.80 (J2ME/MIDP; Opera Mini/9.80 (S60; SymbOS; Opera Mobi/23.348; U; en) Presto/2.5.25 Version/10.54"},
    {"UC Browser",
     "UCWEB/2.0 (MIDP-2.0; U; Adr 9.0.0; en-US; SM-G950F) U2/1.0.0 UCBrowser/12.10"},
    {"IE8", "Mozilla/4.0 (compatible; MSIE 8.0; Windows NT 6.1; Trident/4.0)"},
    {"bare Mozilla/5.0", "Mozilla/5.0"},
    {"iOS AppleCoreMedia",
     "AppleCoreMedia/1.0.0.21E236 (iPhone; U; CPU OS 17_4 like Mac OS X; en_us)"},
    {"Android stagefright", "stagefright/1.2 (Linux;Android 13)"},
    {"ExoPlayer", "ExoPlayerLib/2.19.1"},
    {"VLC", "VLC/3.0.20 LibVLC/3.0.20"},
    {"Roku", "Roku/DVP-12.5 (12.5.0.4176-46)"},
    {"an iOS app over CFNetwork", "MyApp/1.0 CFNetwork/1494.0.7 Darwin/23.4.0"},
    {"Android Dalvik", "Dalvik/2.1.0 (Linux; U; Android 13; Pixel 7 Build/TQ3A.230805.001)"},
    {"okhttp (native Android apps)", "okhttp/4.12.0"}
  ]

  @search_engine [
    {"Googlebot smartphone",
     "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.6367.155 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"},
    {"Googlebot desktop",
     "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"},
    {"Googlebot-Image", "Googlebot-Image/1.0"},
    {"lowercase googlebot", "mozilla/5.0 (compatible; googlebot/2.1)"},
    {"Google-InspectionTool", "Mozilla/5.0 (compatible; Google-InspectionTool/1.0;)"},
    {"the current bingbot",
     "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm) Chrome/116.0.1938.76 Safari/537.36"},
    {"DuckDuckBot", "DuckDuckBot/1.1; (+http://duckduckgo.com/duckduckbot.html)"},
    {"Baiduspider",
     "Mozilla/5.0 (compatible; Baiduspider/2.0; +http://www.baidu.com/search/spider.html)"},
    {"YandexBot", "Mozilla/5.0 (compatible; YandexBot/3.0; +http://yandex.com/bots)"},
    {"Applebot",
     "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.1.1 Safari/605.1.15 (Applebot/0.1; +http://www.apple.com/go/applebot)"},
    # Pinned, not endorsed: a named crawler outranks a library, so this is how
    # cheaply the class is claimed. Spoofable by design (see the moduledoc).
    {"curl claiming Googlebot", "curl Googlebot"}
  ]

  @ai_crawler [
    {"GPTBot",
     "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; GPTBot/1.2; +https://openai.com/gptbot"},
    {"ChatGPT-User",
     "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot"},
    {"ClaudeBot",
     "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0; +claudebot@anthropic.com)"},
    {"anthropic-ai", "anthropic-ai"},
    {"CCBot", "CCBot/2.0 (https://commoncrawl.org/faq/)"},
    {"PerplexityBot",
     "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; PerplexityBot/1.0; +https://perplexity.ai/perplexitybot)"},
    {"Bytespider",
     "Mozilla/5.0 (Linux; Android 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36 (compatible; Bytespider; spider-feedback@bytedance.com)"},
    {"Amazonbot",
     "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Safari/605.1.15 (Amazonbot/0.1; +https://developer.amazon.com/support/amazonbot)"},
    {"meta-externalagent",
     "meta-externalagent/1.1 (+https://developers.facebook.com/docs/sharing/webmasters/crawler)"}
  ]

  @declared_bot [
    {"curl", "curl/8.4.0"},
    {"wget", "Wget/1.21.4"},
    {"python-requests", "python-requests/2.31.0"},
    {"Python-urllib", "Python-urllib/3.11"},
    {"aiohttp", "Python/3.11 aiohttp/3.9.3"},
    {"Go-http-client", "Go-http-client/2.0"},
    {"Java", "Java/17.0.10"},
    {"libwww-perl", "libwww-perl/6.72"},
    {"Scrapy", "Scrapy/2.11.1 (+https://scrapy.org)"},
    {"node-fetch", "node-fetch/1.0 (+https://github.com/bitinn/node-fetch)"},
    {"Req", "req/0.5.6"},
    {"HeadlessChrome",
     "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/124.0.0.0 Safari/537.36"},
    {"AhrefsBot", "Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)"},
    {"PetalBot, browser-shaped",
     "Mozilla/5.0 (Linux; Android 7.0;) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36 (compatible; PetalBot;+https://webmaster.petalsearch.com/site/petalbot)"},
    {"facebookexternalhit",
     "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"},
    {"Twitterbot", "Twitterbot/1.0"},
    {"Slackbot", "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)"},
    {"a generic crawler token",
     "Mozilla/5.0 (compatible; ExampleCrawler/1.0; +https://example.com)"},
    {"a generic token at the end", "SomeSpider"},
    {"GPTBot and Googlebot at once", "GPTBot/1.0 Googlebot/2.1"}
  ]

  for {class, rows} <- [
        browser: @browser,
        search_engine: @search_engine,
        ai_crawler: @ai_crawler,
        declared_bot: @declared_bot
      ],
      {name, ua} <- rows do
    test "#{name} is #{class}" do
      assert BotClass.classify(unquote(ua)) == unquote(class)
    end
  end

  test "nothing, blank or not a string is :empty" do
    for value <- [nil, "", "   ", "\t\n", 42, [:a], %{}] do
      assert BotClass.classify(value) == :empty, inspect(value)
    end
  end

  test "a 10 KB user agent is classified on its first 512 bytes" do
    padding = String.duplicate("a", 10_240)
    assert BotClass.classify("curl/8.4.0 " <> padding) == :declared_bot
    # The name past the cap is never seen.
    assert BotClass.classify(padding <> " GPTBot/1.0") == :browser
  end

  test "invalid UTF-8 does not raise" do
    assert BotClass.classify(<<0xFF, 0xFE, "curl/8.0">>) == :declared_bot
    assert BotClass.classify(<<"Mozilla/5.0 (", 0xC3, 0x28, ") Gecko/1">>) == :browser
    assert BotClass.classify(<<0xFF, 0xFF, 0xFF>>) == :browser
  end

  test "classes/0 lists every answer" do
    assert Enum.sort(BotClass.classes()) ==
             Enum.sort([:browser, :search_engine, :ai_crawler, :declared_bot, :empty])
  end

  describe "search_engine/1 (#2254)" do
    @engine_rows [
      {"Googlebot smartphone",
       "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.6367.155 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
       :google},
      {"Googlebot-Image", "Googlebot-Image/1.0", :google},
      {"lowercase googlebot", "mozilla/5.0 (compatible; googlebot/2.1)", :google},
      {"Google-InspectionTool", "Mozilla/5.0 (compatible; Google-InspectionTool/1.0;)", :google},
      {"bingbot", "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)",
       :bing},
      {"DuckDuckBot", "DuckDuckBot/1.1; (+http://duckduckgo.com/duckduckbot.html)", :duckduckgo},
      {"Baiduspider", "Mozilla/5.0 (compatible; Baiduspider/2.0)", :baidu},
      {"YandexBot", "Mozilla/5.0 (compatible; YandexBot/3.0; +http://yandex.com/bots)", :yandex},
      {"Applebot", "Mozilla/5.0 (Applebot/0.1; +http://www.apple.com/go/applebot)", :apple},
      {"two engines: the leftmost wins", "bingbot/2.0 Googlebot/2.1", :bing}
    ]

    for {name, ua, engine} <- @engine_rows do
      test "#{name} names #{engine}" do
        assert BotClass.search_engine(unquote(ua)) == unquote(engine)
      end
    end

    test "every search-engine row in classify/1 names an engine" do
      for {name, ua} <- @search_engine do
        assert BotClass.search_engine(ua) in BotClass.engines(), name
      end
    end

    test "no other class names an engine" do
      for {name, ua} <- @browser ++ @ai_crawler ++ @declared_bot do
        assert BotClass.search_engine(ua) == nil, name
      end

      for value <- [nil, "", "   ", 42] do
        assert BotClass.search_engine(value) == nil, inspect(value)
      end
    end

    test "a name past the first 512 bytes is never read" do
      assert BotClass.search_engine(String.duplicate("a", 600) <> " Googlebot/2.1") == nil
    end

    test "engines/0 is the table, in order" do
      assert BotClass.engines() == [:google, :bing, :duckduckgo, :baidu, :yandex, :apple]
    end
  end
end
