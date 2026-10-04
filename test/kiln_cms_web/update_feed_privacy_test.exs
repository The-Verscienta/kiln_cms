defmodule KilnCMSWeb.UpdateFeedPrivacyTest do
  @moduledoc """
  #1877: every Kiln instance's update check reads kilncms.dev's
  `GET /api/json/entries/published`, and kilncms.dev keeps no client IP for
  that route. This pins the application's half of that promise — no log line,
  no logger metadata and no error-report context carries the client address —
  for exactly the request `Kiln.Updates` sends. The reverse proxy in front of
  kilncms.dev is the operator's half (see `docs/environment-variables.md`).
  """
  # async: false — the log capture below lowers the global Logger level, and a
  # sync module runs alone, so no other test's output is swept into it.
  use KilnCMSWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  # Documentation ranges (RFC 5737), so a match can only be this test's.
  @peer {203, 0, 113, 77}
  @peer_string "203.0.113.77"
  @forwarded "198.51.100.23"

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "feedpriv-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp published_release_type! do
    actor = admin()

    definition =
      CMS.create_type_definition!(
        %{name: "release#{System.unique_integer([:positive])}", label: "Release"},
        actor: actor
      )

    entry =
      ContentTypes.create!(
        definition.name,
        %{title: "KilnCMS 1.0.0", slug: "v1-0-0-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    {:ok, _} = ContentTypes.transition(definition.name, "publish", entry, actor: actor)
    definition
  end

  # The request `Kiln.Updates` makes, arriving from a distinctive peer through
  # a proxy that names a different client — both addresses must stay out.
  defp feed_request(type_name) do
    build_conn()
    |> Map.put(:remote_ip, @peer)
    |> put_req_header("x-forwarded-for", @forwarded)
    |> put_req_header("user-agent", "KilnCMS")
    |> put_req_header("accept", "application/vnd.api+json")
    |> get(
      "/api/json/entries/published?filter[type_name]=#{type_name}" <>
        "&fields[entry]=custom_fields&page[limit]=100"
    )
  end

  # Debug, globally, for the duration: the suite runs at :warning, which would
  # make an empty capture prove nothing, and a capture cannot go below the
  # primary level. `metadata: :all` prints every printable metadata key, so an
  # address that rode along in metadata is caught too, not only one in a
  # message. (Sentry's request context is not printable metadata; the next
  # test reads it directly.)
  defp capture_everything(fun) do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([level: :debug, metadata: :all], fun)
    after
      Logger.configure(level: previous)
    end
  end

  test "a feed read logs no client address" do
    definition = published_release_type!()

    log =
      capture_everything(fn ->
        conn = feed_request(definition.name)
        assert %{"data" => [_entry]} = json_response(conn, 200)
      end)

    # Otherwise an empty capture — a logger level that swallowed everything —
    # would pass this test for the wrong reason.
    assert log =~ "/api/json/entries/published"
    refute log =~ @peer_string
    refute log =~ @forwarded
  end

  test "an error report for a feed read would carry no client address" do
    definition = published_release_type!()
    _conn = feed_request(definition.name)

    request = Sentry.Context.get_all().request
    assert request.env["REMOTE_ADDR"] == ""
    refute Map.has_key?(request.headers, "x-forwarded-for")
    refute inspect(request) =~ @peer_string
    refute inspect(request) =~ @forwarded
  end

  # The scrubbing is scoped to the feed's route: any other request keeps
  # Sentry's default context, which is a separate policy decision.
  test "other routes keep Sentry's default request context" do
    _conn =
      build_conn()
      |> Map.put(:remote_ip, @peer)
      |> put_req_header("x-forwarded-for", @forwarded)
      |> put_req_header("accept", "application/vnd.api+json")
      |> get("/api/json/entries")

    request = Sentry.Context.get_all().request
    assert request.env["REMOTE_ADDR"] == @forwarded
  end
end
