defmodule Kiln.UpdatesTest do
  @moduledoc """
  The upstream update check.

  The stakes here are trust, not correctness of a feature: an instance that
  cries "update available" when it's current, or stays silent when a security
  release is out, is worse than no check at all. So the comparison boundaries
  and every failure mode are pinned down, and no test is allowed to reach the
  network (`config/test.exs` routes this through a `Req.Test` stub).
  """
  # async: false - the result cache is a :persistent_term shared process-wide,
  # and the disabled case flips global app env.
  use ExUnit.Case, async: false

  alias Kiln.Updates

  setup do
    Updates.clear_cache()
    on_exit(&Updates.clear_cache/0)
    :ok
  end

  defp stub_release(tag, extra \\ %{}) do
    body =
      Map.merge(
        %{
          "tag_name" => tag,
          "html_url" => "https://github.com/The-Verscienta/kiln_cms/releases/tag/#{tag}",
          "published_at" => "2026-07-01T12:00:00Z",
          "body" => "Release notes."
        },
        extra
      )

    Req.Test.stub(Updates, fn conn -> Req.Test.json(conn, body) end)
  end

  defp current_version, do: Kiln.Version.version()

  defp bump(version, part) do
    parsed = Version.parse!(version)

    case part do
      :major -> "#{parsed.major + 1}.0.0"
      :minor -> "#{parsed.major}.#{parsed.minor + 1}.0"
    end
  end

  describe "check/1 when a newer release exists" do
    test "reports the release it is behind" do
      newer = bump(current_version(), :minor)
      stub_release("v#{newer}")

      assert {:ok, {:behind, release}} = Updates.check()
      assert Version.compare(release.version, Version.parse!(newer)) == :eq
      assert release.tag == "v#{newer}"
      assert release.url =~ "releases/tag/v#{newer}"
      assert %DateTime{} = release.published_at
    end

    test "carries a major release through the same path" do
      newer = bump(current_version(), :major)
      stub_release("v#{newer}")

      assert {:ok, {:behind, _release}} = Updates.check()
    end
  end

  describe "check/1 when not behind" do
    test "reports current on an exact match" do
      stub_release("v#{current_version()}")

      assert {:ok, :current} = Updates.check()
    end

    # A dev build pinned past the newest release must not be nagged.
    test "reports current when running ahead of the newest release" do
      stub_release("v0.0.1")

      assert {:ok, :current} = Updates.check()
    end
  end

  describe "tag parsing" do
    test "accepts a tag without the v prefix" do
      stub_release(bump(current_version(), :minor))

      assert {:ok, {:behind, _}} = Updates.check()
    end

    test "errors rather than guessing on an unparseable tag" do
      stub_release("nightly")

      assert {:error, :unparseable_release} = Updates.check()
    end

    test "tolerates a release with no published_at" do
      newer = bump(current_version(), :minor)
      stub_release("v#{newer}", %{"published_at" => nil, "body" => nil})

      assert {:ok, {:behind, release}} = Updates.check()
      assert release.published_at == nil
    end

    test "falls back to the releases index when html_url is absent" do
      newer = bump(current_version(), :minor)
      stub_release("v#{newer}", %{"html_url" => nil})

      assert {:ok, {:behind, release}} = Updates.check()
      assert release.url =~ "/releases"
    end
  end

  describe "failure modes" do
    test "surfaces a non-200 as an http_status error" do
      Req.Test.stub(Updates, fn conn -> Plug.Conn.send_resp(conn, 403, "rate limited") end)

      assert {:error, {:http_status, 403}} = Updates.check()
    end

    test "surfaces a transport failure" do
      Req.Test.stub(Updates, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, _reason} = Updates.check()
    end

    test "reports :disabled without touching the network when turned off" do
      Req.Test.stub(Updates, fn _conn -> flunk("made a request while disabled") end)

      # Merge, don't replace: dropping :req_options would send a stray check
      # to the real api.github.com.
      previous = Application.get_env(:kiln_cms, Updates, [])
      Application.put_env(:kiln_cms, Updates, Keyword.put(previous, :enabled, false))
      on_exit(fn -> Application.put_env(:kiln_cms, Updates, previous) end)

      assert {:error, :disabled} = Updates.check()
    end
  end

  describe "caching" do
    test "serves a repeat check from cache instead of re-requesting" do
      newer = bump(current_version(), :minor)
      stub_release("v#{newer}")

      assert {:ok, {:behind, _}} = Updates.check()

      # Any further request is a cache miss, which this stub turns into a failure.
      Req.Test.stub(Updates, fn _conn -> flunk("re-requested within the TTL") end)

      assert {:ok, {:behind, _}} = Updates.check()
    end

    # The floor is measured from the last *forced* request, so the page's own
    # mount-time check must not make the admin's first click a no-op.
    test "the first forced check bypasses a cached passive result" do
      stub_release("v#{bump(current_version(), :minor)}")
      assert {:ok, {:behind, _}} = Updates.check()

      stub_release("v#{current_version()}")
      assert {:ok, :current} = Updates.check(force: true)
    end

    # Regression: an uncached failure meant a fresh 10s request on EVERY page
    # load during an outage, and once GitHub's 60/hour budget was spent the 403
    # that should have throttled us was the one response we never remembered.
    test "caches failures so an outage doesn't re-request on every call" do
      Req.Test.stub(Updates, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
      assert {:error, {:http_status, 500}} = Updates.check()

      Req.Test.stub(Updates, fn _conn -> flunk("re-requested after a cached failure") end)
      assert {:error, {:http_status, 500}} = Updates.check()
    end

    # Regression: "Check now" issued an unthrottled request per click, so a
    # scripted client could spend the hourly budget in seconds.
    test "throttles repeated forced checks to the cached answer" do
      stub_release("v#{current_version()}")
      assert {:ok, :current} = Updates.check(force: true)

      # A second force inside the floor must serve the cache, not re-request.
      Req.Test.stub(Updates, fn _conn -> flunk("forced check ignored the rate floor") end)
      assert {:ok, :current} = Updates.check(force: true)
    end
  end
end
