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

  # The newest *final* release a running build can be "up to date" with.
  # `releases/latest` never returns a pre-release, so while the running build
  # is a candidate (`1.0.0-rc.1`) the newest release upstream reports is an
  # older final one, and stubbing the running version itself would be a
  # response GitHub cannot send (`Kiln.Updates` refuses it as `:prerelease`).
  defp newest_release do
    v = Version.parse!(Kiln.Version.version())

    cond do
      v.pre == [] -> to_string(v)
      v.patch > 0 -> "#{v.major}.#{v.minor}.#{v.patch - 1}"
      v.minor > 0 -> "#{v.major}.#{v.minor - 1}.0"
      true -> "#{v.major - 1}.0.0"
    end
  end

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
      stub_release("v#{newest_release()}")

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

  # #1541. A release candidate is published with `--prerelease`, and the
  # endpoint asked is `releases/latest`, which GitHub defines as the newest
  # release that is neither a draft nor a pre-release — so a correctly marked
  # candidate never reaches `parse_release`. These pin both halves: the
  # endpoint, and what happens when a candidate was published unmarked.
  describe "pre-releases" do
    test "asks releases/latest, the endpoint that excludes pre-releases" do
      assert {:ok, url} = Updates.releases_url()
      assert String.ends_with?(url, "/releases/latest")

      test_pid = self()

      Req.Test.stub(Updates, fn conn ->
        send(test_pid, {:requested, conn.request_path})
        Req.Test.json(conn, %{"tag_name" => "v#{newest_release()}"})
      end)

      assert {:ok, :current} = Updates.check()
      assert_received {:requested, "/repos/The-Verscienta/kiln_cms/releases/latest"}
    end

    test "an unmarked candidate is refused, never reported as an update" do
      # Newer than this build by any reading — the case that would nag.
      stub_release("v#{bump(current_version(), :major)}-rc.1")

      assert {:error, :prerelease} = Updates.check()
    end

    test "an unmarked candidate is refused even when older than this build" do
      stub_release("v0.0.1-rc.1")

      assert {:error, :prerelease} = Updates.check()
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

      stub_release("v#{newest_release()}")
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
      stub_release("v#{newest_release()}")
      assert {:ok, :current} = Updates.check(force: true)

      # A second force inside the floor must serve the cache, not re-request.
      Req.Test.stub(Updates, fn _conn -> flunk("forced check ignored the rate floor") end)
      assert {:ok, :current} = Updates.check(force: true)
    end
  end

  # #1877. The feed on kilncms.dev is tried first and GitHub is the fallback,
  # so every case here routes the one `Req.Test` stub by host and pins which
  # leg answered — a green comparison alone can't say which one it came from.
  describe "the release feed" do
    @feed_host "kilncms.dev"
    @github_host "api.github.com"

    defp put_updates(key, value) do
      previous = Application.get_env(:kiln_cms, Updates, [])
      Application.put_env(:kiln_cms, Updates, Keyword.put(previous, key, value))
      on_exit(fn -> Application.put_env(:kiln_cms, Updates, previous) end)
    end

    # The shape #1870 publishes: a `release` entry whose custom fields carry
    # the version, date, GitHub link and highlights.
    defp feed_entry(version, fields \\ %{}) do
      %{
        "type" => "entry",
        "id" => Ecto.UUID.generate(),
        "attributes" => %{
          "custom_fields" =>
            Map.merge(
              %{
                "version" => version,
                "released_on" => "2026-10-02",
                "release_url" =>
                  "https://github.com/The-Verscienta/kiln_cms/releases/tag/v#{version}",
                "highlights" => "Lead one\nLead two\n"
              },
              fields
            )
        }
      }
    end

    defp feed_page(entries, next \\ nil) do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/vnd.api+json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"data" => entries, "links" => %{"next" => next}})
        )
      end
    end

    defp github(tag), do: fn conn -> Req.Test.json(conn, %{"tag_name" => tag}) end

    defp unreachable(leg), do: fn _conn -> flunk("requested the #{leg} leg") end

    defp stub_legs(feed, github) do
      Req.Test.stub(Updates, fn conn ->
        case conn.host do
          @feed_host -> feed.(conn)
          @github_host -> github.(conn)
          other -> flunk("requested an unexpected host: #{other}")
        end
      end)
    end

    test "answers from the feed when it has a newer release, without asking GitHub" do
      newer = bump(current_version(), :minor)
      stub_legs(feed_page([feed_entry(newer)]), unreachable("GitHub"))

      assert {:ok, {:behind, release}} = Updates.check()
      assert to_string(release.version) == newer
      assert release.tag == "v#{newer}"
      assert release.url == "https://github.com/The-Verscienta/kiln_cms/releases/tag/v#{newer}"
      assert release.published_at == ~U[2026-10-02 00:00:00Z]
      assert release.highlights == ["Lead one", "Lead two"]
    end

    test "reports current from the feed" do
      stub_legs(feed_page([feed_entry(newest_release())]), unreachable("GitHub"))

      assert {:ok, :current} = Updates.check()
    end

    test "a feed answer is cached like any other" do
      stub_legs(feed_page([feed_entry(bump(current_version(), :minor))]), unreachable("GitHub"))
      assert {:ok, {:behind, _}} = Updates.check()

      Req.Test.stub(Updates, fn _conn -> flunk("re-requested within the TTL") end)
      assert {:ok, {:behind, _}} = Updates.check()
    end

    # Each is a different way for kilncms.dev to fail; none may become the
    # answer, and none may stop GitHub from being asked.
    for {label, feed} <- [
          {"a non-200", quote(do: fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)},
          {"a transport error",
           quote(do: fn conn -> Req.Test.transport_error(conn, :econnrefused) end)},
          {"a body that isn't JSON:API",
           quote(do: fn conn -> Req.Test.json(conn, %{"tag_name" => "v99.0.0"}) end)},
          {"a non-JSON body", quote(do: fn conn -> Plug.Conn.send_resp(conn, 200, "<html>") end)},
          # The feed's state until the site publishes its first release.
          {"an empty feed", quote(do: feed_page([]))},
          {"only unusable entries",
           quote(do: feed_page([feed_entry("nightly"), %{"attributes" => %{}}]))}
        ] do
      test "falls back to GitHub on #{label}" do
        newer = bump(current_version(), :minor)
        stub_legs(unquote(feed), github("v#{newer}"))

        assert {:ok, {:behind, release}} = Updates.check()
        assert release.tag == "v#{newer}"
        assert release.highlights == []
      end
    end

    # The short-TTL error entry is written only when there was no answer at
    # all, and it is GitHub's error — the leg that was asked last.
    test "caches the failure when both legs fail" do
      stub_legs(
        fn conn -> Plug.Conn.send_resp(conn, 503, "down") end,
        fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end
      )

      assert {:error, {:http_status, 500}} = Updates.check()

      Req.Test.stub(Updates, fn _conn -> flunk("re-requested after a cached failure") end)
      assert {:error, {:http_status, 500}} = Updates.check()
    end

    test "picks the highest semver, not the first entry or the highest string" do
      v = Version.parse!(current_version())
      nine = "#{v.major + 1}.9.0"
      ten = "#{v.major + 1}.10.0"
      older = "0.0.1"

      # Newest-published first, as the endpoint sorts: a patch to an older
      # line published after the newest release must not win.
      stub_legs(
        feed_page([feed_entry(older), feed_entry(nine), feed_entry(ten)]),
        unreachable("GitHub")
      )

      assert {:ok, {:behind, release}} = Updates.check()
      assert release.tag == "v#{ten}"
    end

    test "ignores a pre-release in the feed rather than offering it" do
      newer = bump(current_version(), :minor)

      stub_legs(
        feed_page([feed_entry("#{bump(current_version(), :major)}-rc.1"), feed_entry(newer)]),
        unreachable("GitHub")
      )

      assert {:ok, {:behind, release}} = Updates.check()
      assert release.tag == "v#{newer}"
    end

    test "skips malformed entries and keeps the good one" do
      newer = bump(current_version(), :minor)

      entries = [
        %{},
        "not an entry",
        %{"attributes" => %{"custom_fields" => nil}},
        %{"attributes" => %{"custom_fields" => %{}}},
        %{"attributes" => %{"custom_fields" => %{"version" => 99}}},
        feed_entry("not.a.version"),
        feed_entry(newer, %{"released_on" => "yesterday", "highlights" => 7})
      ]

      stub_legs(feed_page(entries), unreachable("GitHub"))

      assert {:ok, {:behind, release}} = Updates.check()
      assert release.tag == "v#{newer}"
      assert release.published_at == nil
      assert release.highlights == []
    end

    # The link is rendered as an href on the admin page.
    test "replaces a non-http release link with the repo's tag page" do
      newer = bump(current_version(), :minor)

      stub_legs(
        feed_page([feed_entry(newer, %{"release_url" => "javascript:alert(1)"})]),
        unreachable("GitHub")
      )

      assert {:ok, {:behind, release}} = Updates.check()
      assert release.url == "https://github.com/The-Verscienta/kiln_cms/releases/tag/v#{newer}"
    end

    test "bounds the highlights a feed entry can put on the page" do
      highlights = Enum.map_join(1..50, "\n", &"Lead #{&1} #{String.duplicate("x", 500)}")

      stub_legs(
        feed_page([feed_entry(bump(current_version(), :minor), %{"highlights" => highlights})]),
        unreachable("GitHub")
      )

      assert {:ok, {:behind, release}} = Updates.check()
      assert length(release.highlights) == 8
      assert Enum.all?(release.highlights, &(String.length(&1) <= 300))
    end

    test "follows links.next on the feed's own origin" do
      newer = bump(current_version(), :minor)
      next = "https://#{@feed_host}/api/json/entries/published?page[after]=cursor"

      stub_legs(
        fn conn ->
          if conn.query_string =~ "cursor",
            do: feed_page([feed_entry(newer)]).(conn),
            else: feed_page([feed_entry("0.0.1")], next).(conn)
        end,
        unreachable("GitHub")
      )

      assert {:ok, {:behind, release}} = Updates.check()
      assert release.tag == "v#{newer}"
    end

    # A `next` on another host would send this instance's request — and its
    # IP — somewhere the operator never configured.
    test "does not follow links.next off the feed's origin" do
      stub_legs(
        feed_page([feed_entry(newest_release())], "https://elsewhere.example/steal"),
        unreachable("GitHub")
      )

      assert {:ok, :current} = Updates.check()
    end

    test "stops paging at the hard cap however many pages the feed claims" do
      pages = :counters.new(1, [])
      next = "https://#{@feed_host}/api/json/entries/published?page[after]=again"

      stub_legs(
        fn conn ->
          :counters.add(pages, 1, 1)
          feed_page([feed_entry(newest_release())], next).(conn)
        end,
        unreachable("GitHub")
      )

      assert {:ok, :current} = Updates.check()
      assert :counters.get(pages, 1) == 5
    end

    # The fork rule (see the moduledoc): the default feed describes upstream,
    # so a deployment pointed elsewhere must not be answered from it.
    test "a fork's KILN_UPDATE_REPO skips the default feed" do
      put_updates(:repo, "acme/kiln")
      stub_legs(unreachable("feed"), github("v#{bump(current_version(), :minor)}"))

      assert {:ok, {:behind, _}} = Updates.check()
      assert Updates.feed_url() == :disabled
    end

    test "KILN_UPDATE_RELEASES_URL skips the default feed" do
      put_updates(:releases_url, "https://ghe.example.com/api/v3/repos/acme/kiln/releases/latest")

      Req.Test.stub(Updates, fn conn ->
        assert conn.host == "ghe.example.com"
        Req.Test.json(conn, %{"tag_name" => "v#{newest_release()}"})
      end)

      assert {:ok, :current} = Updates.check()
      assert Updates.feed_url() == :disabled
    end

    test "naming the canonical repo explicitly still uses the feed" do
      put_updates(:repo, "The-Verscienta/kiln_cms")
      stub_legs(feed_page([feed_entry(newest_release())]), unreachable("GitHub"))

      assert {:ok, :current} = Updates.check()
    end

    test "a fork that sets its own feed URL is answered from that feed" do
      put_updates(:repo, "acme/kiln")
      put_updates(:feed_url, "https://kiln.acme.example/api/json/entries/published")
      newer = bump(current_version(), :minor)

      Req.Test.stub(Updates, fn conn ->
        assert conn.host == "kiln.acme.example"
        assert conn.request_path == "/api/json/entries/published"
        feed_page([feed_entry(newer, %{"release_url" => nil})]).(conn)
      end)

      assert {:ok, {:behind, release}} = Updates.check()
      # Without a link of its own, the release points at the fork's repo.
      assert release.url == "https://github.com/acme/kiln/releases/tag/v#{newer}"
    end

    test "feed_url: false is GitHub-only" do
      put_updates(:feed_url, false)
      stub_legs(unreachable("feed"), github("v#{newest_release()}"))

      assert Updates.feed_url() == :disabled
      assert {:ok, :current} = Updates.check()
    end

    test "a blank feed URL reads as unset, not as off" do
      put_updates(:feed_url, "  ")
      assert Updates.feed_url() == {:ok, "https://kilncms.dev/api/json/entries/published"}
    end

    test "a malformed feed URL falls back to GitHub, with a warning" do
      put_updates(:feed_url, "kilncms.dev/api/json/entries/published")
      stub_legs(unreachable("feed"), github("v#{newest_release()}"))

      assert Updates.feed_url() == {:error, :invalid_feed_url}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :current} = Updates.check()
        end)

      assert log =~ "KILN_UPDATE_FEED_URL"
    end

    # #1877's privacy requirement: the request may say "a Kiln asked" and
    # nothing more. Asserted on both legs, on what actually left the client.
    test "sends no identifying headers or parameters on either leg" do
      test_pid = self()

      stub_legs(
        fn conn ->
          send(test_pid, {:feed, conn})
          Plug.Conn.send_resp(conn, 503, "down")
        end,
        fn conn ->
          send(test_pid, {:github, conn})
          Req.Test.json(conn, %{"tag_name" => "v#{newest_release()}"})
        end
      )

      assert {:ok, :current} = Updates.check()
      assert_received {:feed, feed}
      assert_received {:github, github}

      assert Plug.Conn.fetch_query_params(feed).query_params == %{
               "filter" => %{"type_name" => "release"},
               "fields" => %{"entry" => "custom_fields"},
               "page" => %{"limit" => "100"}
             }

      assert github.query_string == ""

      for conn <- [feed, github] do
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["KilnCMS"]

        # A subset rather than an exact list: transport-level headers vary by
        # adapter, and none of these three can carry anything identifying.
        sent_headers = Enum.map(conn.req_headers, &elem(&1, 0))
        assert sent_headers -- ~w(accept accept-encoding user-agent) == []

        sent = conn.request_path <> conn.query_string <> inspect(conn.req_headers)
        refute sent =~ Kiln.Version.version()
      end
    end
  end
end
