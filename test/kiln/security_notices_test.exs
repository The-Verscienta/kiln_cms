defmodule Kiln.SecurityNoticesTest do
  @moduledoc """
  The shared security notices fetch (#2522): where the feed is, that nothing
  is asked when there is none, that every answer is cached, and that callers
  arriving together share one request. Requests go to the
  `Kiln.SecurityNotices` `Req.Test` stub (`config/test.exs`).
  """
  # async: false - the cache is a :persistent_term shared VM-wide, the warmer
  # a node-wide registered name, and these cases flip `Kiln.SecurityNotices`
  # and `Kiln.Updates` app env.
  use ExUnit.Case, async: false

  # An invalid URL logs a warning.
  @moduletag :capture_log

  import KilnCMS.Test.Eventually, only: [eventually: 1]

  alias Kiln.Plugins.Health.Notice
  alias Kiln.SecurityNotices

  @default "https://kilncms.dev/api/json/entries/published"

  setup do
    notices = Application.get_env(:kiln_cms, SecurityNotices, [])
    updates = Application.get_env(:kiln_cms, Kiln.Updates, [])

    SecurityNotices.clear_cache()

    # The feed is off in the test config; unset, it follows the update feed
    # (kilncms.dev's), as in production.
    put_notices(url: nil)
    put_updates(repo: nil, releases_url: nil, feed_url: nil)

    on_exit(fn ->
      Application.put_env(:kiln_cms, SecurityNotices, notices)
      Application.put_env(:kiln_cms, Kiln.Updates, updates)
      SecurityNotices.clear_cache()
    end)

    :ok
  end

  defp put_notices(pairs) do
    Application.put_env(
      :kiln_cms,
      SecurityNotices,
      Keyword.merge(Application.get_env(:kiln_cms, SecurityNotices, []), pairs)
    )
  end

  defp put_updates(pairs) do
    Application.put_env(
      :kiln_cms,
      Kiln.Updates,
      Keyword.merge(Application.get_env(:kiln_cms, Kiln.Updates, []), pairs)
    )
  end

  defp entry(id, fields) do
    %{"id" => id, "attributes" => %{"title" => "Notice #{id}", "custom_fields" => fields}}
  end

  # Answers like kilncms.dev's published-entries endpoint (or with `answer`),
  # and tells the test about every request.
  defp stub(answer \\ &Req.Test.json(&1, %{"data" => [entry("1", %{"package" => "kiln_cms"})]})) do
    test = self()

    Req.Test.stub(SecurityNotices, fn conn ->
      send(test, {:request, conn.host, conn.request_path})
      answer.(conn)
    end)
  end

  defp requests do
    receive do
      {:request, host, path} -> [{host, path} | requests()]
    after
      0 -> []
    end
  end

  describe "url/0" do
    test "defaults to kilncms.dev while the update feed is kilncms.dev's" do
      assert SecurityNotices.url() == {:ok, @default}
    end

    test "a fork (KILN_UPDATE_REPO) gets no default feed" do
      put_updates(repo: "someone/fork")
      assert SecurityNotices.url() == :disabled
    end

    test "a mirror (KILN_UPDATE_RELEASES_URL) gets no default feed" do
      put_updates(releases_url: "https://ghe.example/api/v3/repos/a/b/releases/latest")
      assert SecurityNotices.url() == :disabled
    end

    test "KILN_UPDATE_FEED_URL=false turns the default off" do
      put_updates(feed_url: false)
      assert SecurityNotices.url() == :disabled
    end

    test "an explicit URL wins over the fork rule" do
      put_updates(repo: "someone/fork")
      put_notices(url: "https://fork.example/api/json/entries/published")
      assert SecurityNotices.url() == {:ok, "https://fork.example/api/json/entries/published"}
    end

    test "explicit false is off; blank is unset; garbage is an error" do
      put_notices(url: false)
      assert SecurityNotices.url() == :disabled

      put_notices(url: "  ")
      assert SecurityNotices.url() == {:ok, @default}

      put_notices(url: "kilncms.dev/feed")
      assert SecurityNotices.url() == {:error, :invalid_notices_url}
    end
  end

  describe "with no feed to ask" do
    test "nothing is requested, whichever way the feed is off" do
      stub()

      for off <- [
            fn -> put_notices(url: false) end,
            fn -> put_updates(repo: "someone/fork") end,
            fn ->
              put_updates(releases_url: "https://ghe.example/api/v3/repos/a/b/releases/latest")
            end,
            fn -> put_updates(feed_url: false) end
          ] do
        put_notices(url: nil)
        put_updates(repo: nil, releases_url: nil, feed_url: nil)
        off.()

        assert SecurityNotices.fetch() == :disabled
        assert SecurityNotices.fetch(force: true) == :disabled
        assert SecurityNotices.cached() == :disabled
        assert SecurityNotices.warm() == :disabled
        assert SecurityNotices.checked_at() == nil
      end

      assert requests() == []
    end

    test "an invalid URL is an error, logged, and never requested" do
      stub()
      put_notices(url: "kilncms.dev/feed")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert SecurityNotices.fetch() == {:error, :invalid_notices_url}
        end)

      assert log =~ "KILN_SECURITY_NOTICES_URL is not an absolute http(s) URL"
      assert SecurityNotices.cached() == {:error, :invalid_notices_url}
      assert SecurityNotices.warm() == :cached
      assert requests() == []
    end
  end

  describe "fetch/1 and cached/0" do
    test "a cold cache reads nil without a request" do
      stub()

      assert SecurityNotices.cached() == nil
      assert SecurityNotices.checked_at() == nil
      assert requests() == []
    end

    test "fetches once, then answers from the cache" do
      stub()

      assert {:ok, [%Notice{packages: ["kiln_cms"], source: :kiln}]} = SecurityNotices.fetch()
      assert requests() == [{"kilncms.dev", "/api/json/entries/published"}]

      assert {:ok, [%Notice{}]} = SecurityNotices.fetch()
      assert {:ok, [%Notice{}]} = SecurityNotices.cached()
      assert %DateTime{} = SecurityNotices.checked_at()
      assert requests() == []
    end

    test "a failure is cached rather than retried on every read" do
      stub(&Plug.Conn.send_resp(&1, 503, "down"))

      assert SecurityNotices.fetch() == {:error, {:http_status, 503}}
      assert [_] = requests()

      assert SecurityNotices.fetch() == {:error, {:http_status, 503}}
      assert SecurityNotices.cached() == {:error, {:http_status, 503}}
      assert requests() == []
    end

    test "a crash is an answer, cached, and leaves the caller standing" do
      stub(fn _conn -> raise "boom" end)

      assert {:error, {:crashed, _kind}} = SecurityNotices.fetch()
      assert {:error, {:crashed, _kind}} = SecurityNotices.cached()
      assert Process.alive?(self())
    end

    test "a feed that does not answer in time is a timeout, cached" do
      stub(fn conn ->
        Process.sleep(500)
        Req.Test.json(conn, %{"data" => []})
      end)

      assert SecurityNotices.fetch(timeout: 50) == {:error, :timeout}
      assert SecurityNotices.cached() == {:error, :timeout}
    end

    test "an answer serves only the URL it came from" do
      SecurityNotices.put_cache({:ok, []})
      assert SecurityNotices.cached() == {:ok, []}

      put_notices(url: "https://mirror.example/api/json/entries/published")
      assert SecurityNotices.cached() == nil
    end
  end

  describe "forcing" do
    test "bypasses a fresh cache the first time" do
      stub()
      SecurityNotices.put_cache({:ok, []})

      assert {:ok, [_notice]} = SecurityNotices.fetch(force: true)
      assert [_] = requests()
    end

    test "is floored at one request a minute, served from the cache inside it" do
      stub()

      assert {:ok, [_notice]} = SecurityNotices.fetch(force: true)
      assert [_] = requests()

      assert {:ok, [_notice]} = SecurityNotices.fetch(force: true)
      assert requests() == []
    end
  end

  # Two callers on a cold cache (the plugin check and the core check render
  # side by side) must share one request, not race to make two.
  describe "single flight" do
    defp slow_stub do
      stub(fn conn ->
        Process.sleep(100)
        Req.Test.json(conn, %{"data" => []})
      end)
    end

    test "concurrent fetches on a cold cache make exactly one request" do
      slow_stub()

      results =
        [fn -> SecurityNotices.fetch() end, fn -> SecurityNotices.fetch() end]
        |> Enum.map(&Task.async/1)
        |> Task.await_many(30_000)

      assert results == [{:ok, []}, {:ok, []}]
      assert requests() == [{"kilncms.dev", "/api/json/entries/published"}]
    end

    test "concurrent forced fetches make exactly one request" do
      slow_stub()

      results =
        [
          fn -> SecurityNotices.fetch(force: true) end,
          fn -> SecurityNotices.fetch(force: true) end
        ]
        |> Enum.map(&Task.async/1)
        |> Task.await_many(30_000)

      assert results == [{:ok, []}, {:ok, []}]
      assert requests() == [{"kilncms.dev", "/api/json/entries/published"}]
    end
  end

  describe "warm/0" do
    test "starts one background fetch, which fills the cache" do
      stub()

      assert SecurityNotices.warm() == :started
      eventually(fn -> SecurityNotices.cached() != nil end)
      eventually(fn -> Process.whereis(SecurityNotices.warmer_name()) == nil end)

      assert {:ok, [_notice]} = SecurityNotices.cached()
      assert requests() == [{"kilncms.dev", "/api/json/entries/published"}]
      assert SecurityNotices.warm() == :cached
    end

    test "answers :cached when the cache is warm" do
      SecurityNotices.put_cache({:ok, []})
      assert SecurityNotices.warm() == :cached
    end

    test "answers :in_flight while a warmer runs" do
      Process.register(self(), SecurityNotices.warmer_name())

      try do
        assert SecurityNotices.warm() == :in_flight
      after
        Process.unregister(SecurityNotices.warmer_name())
      end
    end
  end
end
