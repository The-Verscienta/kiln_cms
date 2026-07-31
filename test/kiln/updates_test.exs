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

  # A fork left on the default is told about someone else's releases, and it
  # fails silently in the worst direction: ahead of upstream, `compare/2` reads
  # `:gt` and the page says "Up to date" forever, so the fork's own security
  # releases never surface. Hence the request URL is asserted directly rather
  # than inferred from a green comparison — the comparison is green either way.
  describe "repo/0 and releases_url/0" do
    defp put_config(key, value) do
      previous = Application.get_env(:kiln_cms, Updates, [])
      Application.put_env(:kiln_cms, Updates, Keyword.put(previous, key, value))
      on_exit(fn -> Application.put_env(:kiln_cms, Updates, previous) end)
    end

    test "defaults to the canonical repo" do
      assert Updates.repo() == {:ok, "The-Verscienta/kiln_cms"}

      assert Updates.releases_url() ==
               {:ok, "https://api.github.com/repos/The-Verscienta/kiln_cms/releases/latest"}
    end

    test "a configured fork replaces the repo in the endpoint" do
      put_config(:repo, "acme/kiln")

      assert Updates.repo() == {:ok, "acme/kiln"}

      assert Updates.releases_url() ==
               {:ok, "https://api.github.com/repos/acme/kiln/releases/latest"}
    end

    test "blank and padded values behave like the sibling pin path" do
      put_config(:repo, "  ")
      assert Updates.repo() == {:ok, "The-Verscienta/kiln_cms"}

      put_config(:repo, " acme/kiln\n")
      assert Updates.repo() == {:ok, "acme/kiln"}
    end

    # Falling back to the default on a typo would reinstate the exact silent
    # wrong-repo comparison this key exists to remove, so it fails closed.
    for bad <- ["acmekiln", "acme/kiln/extra", "../../etc", "acme/kiln?x=1", "https://x/y"] do
      test "rejects #{inspect(bad)} rather than falling back to upstream" do
        put_config(:repo, unquote(bad))

        assert Updates.repo() == {:error, :invalid_repo}
        assert Updates.releases_url() == {:error, :invalid_repo}
      end
    end

    test "requests the configured repo's endpoint, not upstream's" do
      newer = bump(current_version(), :minor)
      put_config(:repo, "acme/kiln")

      Req.Test.stub(Updates, fn conn ->
        assert conn.request_path == "/repos/acme/kiln/releases/latest"
        Req.Test.json(conn, %{"tag_name" => "v#{newer}", "html_url" => nil})
      end)

      assert {:ok, {:behind, release}} = Updates.check()
      # The html_url fallback follows the same repo — otherwise "Update
      # available" would link a fork's admin at upstream's releases page.
      assert release.url == "https://github.com/acme/kiln/releases"
    end

    test "a full releases URL repoints the endpoint for Enterprise or a mirror" do
      newer = bump(current_version(), :minor)
      put_config(:releases_url, "https://ghe.example.com/api/v3/repos/acme/kiln/releases/latest")

      assert Updates.releases_url() ==
               {:ok, "https://ghe.example.com/api/v3/repos/acme/kiln/releases/latest"}

      Req.Test.stub(Updates, fn conn ->
        assert conn.host == "ghe.example.com"
        assert conn.request_path == "/api/v3/repos/acme/kiln/releases/latest"
        Req.Test.json(conn, %{"tag_name" => "v#{newer}"})
      end)

      assert {:ok, {:behind, _}} = Updates.check()
    end

    # `Req.request/1` raises on a URL with no scheme, and the check runs inside
    # the system page's `start_async` — a raise there takes the LiveView down
    # instead of rendering a status.
    test "rejects a releases URL that is not an absolute http(s) URL" do
      Req.Test.stub(Updates, fn _conn -> flunk("requested a malformed endpoint") end)

      put_config(:releases_url, "api.github.com/repos/acme/kiln/releases/latest")

      assert Updates.releases_url() == {:error, :invalid_releases_url}
      assert Updates.check() == {:error, :invalid_releases_url}
    end

    # The endpoint override doesn't rescue a malformed repo: the repo still
    # supplies the html_url fallback, so a set-but-broken value fails closed.
    test "a malformed repo fails closed even when the endpoint is overridden" do
      Req.Test.stub(Updates, fn _conn -> flunk("requested with a malformed repo") end)

      put_config(:repo, "acmekiln")
      put_config(:releases_url, "https://ghe.example.com/api/v3/repos/acme/kiln/releases/latest")

      assert Updates.check() == {:error, :invalid_repo}
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

  # The pin's path is a downstream layout choice — submodule or fetched ref, at
  # whatever path — and an image has no checkout to look in. So it is operator
  # input with no default: a guessed default would be a wrong `cd` compiled
  # into the image, which the admin page offers no way to correct.
  describe "pin_path/0" do
    defp put_pin_path(value) do
      previous = Application.get_env(:kiln_cms, Updates, [])
      Application.put_env(:kiln_cms, Updates, Keyword.put(previous, :pin_path, value))
      on_exit(fn -> Application.put_env(:kiln_cms, Updates, previous) end)
    end

    test "is nil when unconfigured" do
      assert Updates.pin_path() == nil
    end

    test "returns the configured path" do
      put_pin_path("kiln/upstream")

      assert Updates.pin_path() == "kiln/upstream"
    end

    test "treats a blank value as unconfigured" do
      put_pin_path("   ")

      assert Updates.pin_path() == nil
    end

    test "trims surrounding whitespace" do
      put_pin_path(" upstream\n")

      assert Updates.pin_path() == "upstream"
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
