defmodule Kiln.Updates do
  @moduledoc """
  Whether a newer Kiln release exists upstream.

  This is the *reporting* half of the update story; `mix kiln.update` is the
  half that changes anything. A deployed instance runs from an immutable image
  built off a pinned submodule (see `projects/README.md`), so it cannot update
  itself — it can only tell an admin that it's behind and print the command.

  ## Why a feed and not git

  `mix kiln.update` reads tags from the checkout it runs in. A running
  container has no checkout, so this module asks over HTTP instead, in two
  legs (#1877):

    1. **The release feed on kilncms.dev**, tried first. kilncms.dev is itself
       a Kiln instance, and each final release is published there as an entry
       of the `release` content type (#1870), so the feed is just the generic
       public read API every Kiln serves —
       `GET /api/json/entries/published?filter[type_name]=release`. It is not
       subject to GitHub's 60-requests-per-hour unauthenticated budget, and it
       carries each release's highlights, which the update page lists.
    2. **The GitHub releases API**, on *any* failure of the first leg —
       unreachable, a non-200, a body that isn't the expected JSON:API shape,
       or no entry with a parseable final version (which is also what the feed
       answers until the site has published its first release). An outage of
       kilncms.dev therefore only changes where the answer comes from.

  The feed is paged at 100 entries and `links.next` is followed for at most
  five pages, and only while it stays on the feed's own origin. The highest
  semver among the entries wins, compared here rather than trusting any server
  sort, since a patch to an older line can be published after a newer major.

  Either leg sees a version only once its tag has an accompanying GitHub
  *release* (the feed is published from it) — which is the point of the
  release checklist in `docs/releasing.md`.

  ## Which upstream

  Whichever one this deployment was told, via `repo/0` and `releases_url/0` —
  defaulting to the canonical repo, but *only* as a default. A fork that keeps
  comparing itself against `The-Verscienta/kiln_cms` gets an answer about
  someone else's code: behind upstream it nags forever about a release its
  codebase does not contain, and ahead of upstream `compare/2` reads `:gt` and
  reports "Up to date" indefinitely, so the fork's own security releases never
  surface.

  The feed obeys the same rule. It describes *upstream* releases, so it is
  consulted by default only while this deployment compares itself against
  upstream: `KILN_UPDATE_REPO` unset (or set to the canonical repo) and
  `KILN_UPDATE_RELEASES_URL` unset. A fork that set `KILN_UPDATE_REPO`, or a
  GitHub Enterprise / air-gapped install that set `KILN_UPDATE_RELEASES_URL`,
  goes straight to its own GitHub endpoint — otherwise kilncms.dev would answer
  first and every fork would be told about upstream again, which is the exact
  failure the repo setting exists to prevent, and a mirror chosen to keep
  traffic internal would start reaching the internet. Such a deployment opts
  back in by setting `KILN_UPDATE_FEED_URL` explicitly (its own site's feed,
  typically). `KILN_UPDATE_FEED_URL=false` turns the feed leg off everywhere,
  leaving GitHub only.

  ## Pre-releases

  The feed publishes final releases only (#1870), but the publishing script
  can be told to publish a candidate, so the feed leg ignores any entry whose
  version has a pre-release part rather than offering it.

  `releases/latest` is GitHub's newest release that is neither a draft nor
  marked as a pre-release, so a release candidate published with
  `gh release create --prerelease` (see `docs/releasing.md`) is never offered
  here. One published *without* the flag would be; its tag is refused as
  `{:error, :prerelease}` instead of being reported as an update.

  ## Network behaviour

  Made only when an admin opens the update page: one unauthenticated GET to the
  feed (more only if it pages), and a GET to the GitHub releases API only if
  the feed failed. Both are public reads. Each request carries a bare
  `KilnCMS` user-agent and nothing else that could identify the instance: no
  version, no host name, no instance identifier, no cookie or credential, and
  no query parameters beyond the feed's fixed type filter, field list and page
  size. kilncms.dev keeps no client IP for the feed route (#1877). Operators
  who want no outbound traffic at all set `KILN_UPDATE_CHECK=false`, and
  `check/1` then reports `:disabled` without touching the network.

  Every outcome is cached in `:persistent_term` — 24h for a comparison, 15
  minutes for a failure — and forced checks are floored at one per minute. The
  two legs share that cache and that floor: a check is one cached answer
  however many legs it took, and the 15-minute error entry is written only
  when *both* failed.
  Caching failures matters as much as caching successes: unauthenticated
  api.github.com allows 60 requests/hour/IP, and if a 403 went uncached the
  instance would keep requesting on every page load and never recover from
  having spent its budget.

  The cache dies with the VM, so a restart re-checks on the next admin visit.
  That's deliberate: it's a courtesy to GitHub's rate limiter, not durable
  state worth a migration.
  """

  require Logger

  alias Kiln.Version, as: Build

  @cache_key {__MODULE__, :latest}
  @force_key {__MODULE__, :last_forced_at}
  @ttl_ms :timer.hours(24)

  # Failures are cached too, for much less time. Not caching them at all means
  # every page load re-requests while upstream is unreachable — and once the
  # unauthenticated 60/hour budget is gone, the 403 that should throttle us is
  # the very response that isn't cached, so the instance never recovers.
  @error_ttl_ms :timer.minutes(15)

  # Floor between forced ("Check now") requests. The button is client-side
  # disabled while loading, which is no defence against a scripted client, and
  # an authenticated admin should not be able to burn the hourly budget.
  @min_force_interval_ms :timer.seconds(60)

  # The repo this build compares itself against when nobody says otherwise.
  #
  # Unlike the sibling `:pin_path`, a default is honest here: the pin's path is
  # a downstream layout choice with no right answer, whereas an unmodified
  # install *is* this repo. What must not happen is a **misconfigured** install
  # quietly landing on it — see `repo/0`.
  @default_repo "The-Verscienta/kiln_cms"

  @github_api "https://api.github.com"
  @github_web "https://github.com"

  # The release feed (#1877): kilncms.dev's generic published-entries read,
  # filtered to the `release` type that #1870 publishes into.
  @default_feed_url "https://kilncms.dev/api/json/entries/published"
  @feed_type "release"

  # `100` is the `:published` action's `max_page_size`; asking for more is
  # clamped server-side anyway. Five pages is 500 releases — years of headroom
  # — and a hard bound on how many requests one check can make, whatever the
  # `next` links say.
  @feed_page_size 100
  @feed_max_pages 5

  # The page lists these under "Update available"; a feed entry is someone
  # else's data, so it does not get to make the page arbitrarily long.
  @max_highlights 8
  @max_highlight_length 300

  # `owner/name`, GitHub's own shape. Deliberately strict: anything else is a
  # typo, and interpolating a typo would resolve somewhere else under
  # api.github.com rather than fail.
  @repo_format ~r{\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\z}

  @typedoc """
  The outcome of an upstream check.

    * `{:ok, :current}` — running the newest release, or newer than it;
    * `{:ok, {:behind, release}}` — a newer release exists;
    * `{:error, :disabled}` — the operator turned checks off;
    * `{:error, :unknown_version}` — this build's version doesn't parse, so no
      comparison is meaningful;
    * `{:error, :invalid_repo}` / `{:error, :invalid_releases_url}` — the
      upstream this instance was pointed at is unusable, so no request was
      made;
    * `{:error, :prerelease}` — upstream's "latest" release is a pre-release
      tag (`v1.0.0-rc.1`) that was published without being marked as one, so
      there is no final release to compare against;
    * `{:error, reason}` — the check itself failed (offline, rate-limited).
  """
  @type result ::
          {:ok, :current}
          | {:ok, {:behind, release()}}
          | {:error,
             :disabled
             | :unknown_version
             | :invalid_repo
             | :invalid_releases_url
             | :prerelease
             | term()}

  @typedoc """
  The newest upstream release. `highlights` is the release's headline changes,
  one per line, as the feed publishes them; it is `[]` when the answer came
  from the GitHub leg, which has no such field.
  """
  @type release :: %{
          version: Version.t(),
          tag: String.t(),
          url: String.t(),
          published_at: DateTime.t() | nil,
          highlights: [String.t()]
        }

  @doc """
  Compares this build against the newest upstream release.

  Serves a cached answer when one is fresh — 24h for a successful comparison,
  15 minutes for a failure. `force: true` (the page's "check now" action)
  bypasses the TTL but still honours a 60-second floor between requests, so a
  scripted client can't spend the hourly budget.
  """
  @spec check(keyword()) :: result()
  def check(opts \\ []) do
    cond do
      not enabled?() -> {:error, :disabled}
      opts[:force] -> forced_check()
      cached = cached_result() -> cached
      true -> fetch_and_compare()
    end
  end

  # The floor is measured from the last *forced* request, not from the last
  # cached answer — otherwise the page's own mount-time check would make the
  # admin's first "Check now" click a no-op. A throttled force falls back to
  # the normal cache-aside path, so a scripted loop settles into serving the
  # cached value instead of issuing requests.
  defp forced_check do
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get(@force_key, nil)

    if last && now - last < @min_force_interval_ms do
      cached_result() || fetch_and_compare()
    else
      :persistent_term.put(@force_key, now)
      fetch_and_compare()
    end
  end

  @doc "Whether update checking is enabled (`KILN_UPDATE_CHECK=false` disables it)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:kiln_cms, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @doc """
  The `owner/name` this instance compares itself against.

  Defaults to `#{@default_repo}`, overridden by `KILN_UPDATE_REPO` so a fork
  is told about *its own* releases. Comparing a fork against upstream is not a
  cosmetic mismatch: a fork ahead of upstream reads `:gt`, which `compare/2`
  treats as current, so the page says "Up to date" forever and the fork's own
  security releases never surface.

  A configured value that isn't `owner/name` is rejected rather than ignored.
  Falling back to the default on a typo would reintroduce exactly the silent
  wrong-repo comparison this key exists to prevent, so it fails closed and the
  page says the check is misconfigured.
  """
  @spec repo() :: {:ok, String.t()} | {:error, :invalid_repo}
  def repo do
    case config_string(:repo) do
      nil -> {:ok, @default_repo}
      repo -> if Regex.match?(@repo_format, repo), do: {:ok, repo}, else: {:error, :invalid_repo}
    end
  end

  @doc """
  The releases endpoint to GET, derived from `repo/0` unless overridden.

  `KILN_UPDATE_REPO` covers forks on github.com; `KILN_UPDATE_RELEASES_URL`
  covers the installs that aren't there at all — GitHub Enterprise, or an
  internal mirror on an air-gapped network, which otherwise sit in a permanent
  error state with no way to repoint the check.

  It overrides the endpoint only. The link the page offers still comes from
  the release's own `html_url`; `repo/0` supplies the fallback for the rare
  response that omits one, so an Enterprise operator generally wants to set
  both keys.
  """
  @spec releases_url() :: {:ok, String.t()} | {:error, :invalid_repo | :invalid_releases_url}
  def releases_url do
    with {:ok, repo} <- repo(), do: releases_url(repo)
  end

  defp releases_url(repo) do
    case config_string(:releases_url) do
      nil ->
        {:ok, "#{@github_api}/repos/#{repo}/releases/latest"}

      url ->
        # Validated, not trusted: `Req.request/1` raises on a URL with no
        # scheme, and this call runs inside the update page's `start_async`,
        # where a raise takes the LiveView down instead of rendering a status.
        case URI.new(url) do
          {:ok, %URI{scheme: scheme, host: host}}
          when scheme in ~w(http https) and is_binary(host) ->
            {:ok, url}

          _ ->
            {:error, :invalid_releases_url}
        end
    end
  end

  @doc """
  The release feed tried before GitHub, or `:disabled`.

    * `KILN_UPDATE_FEED_URL=false` (any off-spelling) — `:disabled`, so the
      check is GitHub-only;
    * `KILN_UPDATE_FEED_URL=<url>` — that URL, whatever `repo/0` says. It is
      the published-entries endpoint of a Kiln site
      (`https://site.example/api/json/entries/published`); this module adds the
      query;
    * unset — `#{@default_feed_url}`, but **only** while this deployment
      compares itself against upstream. A configured `KILN_UPDATE_REPO` other
      than `#{@default_repo}`, or any `KILN_UPDATE_RELEASES_URL`, makes it
      `:disabled`: the default feed describes upstream's releases, and
      answering a fork from it is the wrong-repo comparison `repo/0` exists to
      prevent.

  A configured value that isn't an absolute http(s) URL is
  `{:error, :invalid_feed_url}`. Unlike `releases_url/0` that does not fail
  the check — the GitHub leg is still the right answer for the configured repo
  — but it is logged, since the operator asked for a feed and isn't getting it.
  """
  @spec feed_url() :: {:ok, String.t()} | :disabled | {:error, :invalid_feed_url}
  def feed_url do
    cond do
      Application.get_env(:kiln_cms, __MODULE__, []) |> Keyword.get(:feed_url) == false ->
        :disabled

      url = config_string(:feed_url) ->
        validate_http_url(url, :invalid_feed_url)

      upstream?() ->
        {:ok, @default_feed_url}

      true ->
        :disabled
    end
  end

  defp upstream? do
    config_string(:releases_url) == nil and config_string(:repo) in [nil, @default_repo]
  end

  defp validate_http_url(url, error) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ~w(http https) and is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, error}
    end
  end

  @doc """
  Where an operator runs `mix kiln.update` from, if this deployment was told.

  `nil` unless `KILN_PIN_PATH` is set, and the admin page then gives a
  layout-agnostic instruction instead of a `cd`. That default is deliberate:
  `projects/README.md` documents the pin as a submodule *or a fetched ref* at
  a path the project picks, so there is no path an image could hardcode
  honestly — and a wrong `cd` compiled into the image is a copy-pasteable
  `no such file or directory` the page has no way to correct.

  It is display only. Nothing here reads or writes that path; a running
  instance has no checkout to reach.
  """
  @spec pin_path() :: String.t() | nil
  def pin_path, do: config_string(:pin_path)

  # A blank value reads as unset throughout: `runtime.exs` only sets these keys
  # when the variable is non-empty, but a release template or compose file that
  # passes an empty string must mean the same thing as leaving it out.
  defp config_string(key) do
    case Application.get_env(:kiln_cms, __MODULE__, []) |> Keyword.get(key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc false
  # Exposed so tests can start from a known cache state.
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :persistent_term.erase(@force_key)
    :ok
  end

  defp cached_result do
    case :persistent_term.get(@cache_key, nil) do
      {stored_at, result} ->
        age = System.monotonic_time(:millisecond) - stored_at
        if age < ttl_for(result), do: result

      nil ->
        nil
    end
  end

  defp ttl_for({:ok, _}), do: @ttl_ms
  defp ttl_for(_error), do: @error_ttl_ms

  # Both outcomes are cached. A failure gets the short TTL so a transient blip
  # clears quickly, while a sustained outage (or a 403 after the rate limit is
  # spent) can no longer trigger a fresh request on every single page load.
  defp cache(result) do
    :persistent_term.put(@cache_key, {System.monotonic_time(:millisecond), result})
    result
  end

  defp fetch_and_compare do
    with {:ok, current} <- current_version(),
         {:ok, release} <- fetch_latest() do
      compare(current, release)
    end
    |> cache()
  end

  defp current_version do
    case Version.parse(Build.version()) do
      {:ok, version} -> {:ok, version}
      :error -> {:error, :unknown_version}
    end
  end

  # `:gt` (running ahead of the newest release) counts as current — that's a
  # developer build or an unreleased pin, not something to nag about.
  defp compare(current, release) do
    case Version.compare(release.version, current) do
      :gt -> {:ok, {:behind, release}}
      _ -> {:ok, :current}
    end
  end

  # The repo is resolved even when `:releases_url` overrides the endpoint: it
  # still supplies the `html_url` fallback below, and a repo that is set but
  # malformed should fail closed rather than be silently unused. That happens
  # before either leg, so a misconfigured install makes no request at all —
  # not even to the feed, whose answer would be about some other repo.
  #
  # The feed's failure reason is deliberately dropped: the GitHub leg is the
  # answer then, and its error (if any) is the one cached and shown.
  defp fetch_latest do
    with {:ok, repo} <- repo(),
         {:ok, endpoint} <- releases_url(repo) do
      case fetch_feed(repo) do
        {:ok, release} -> {:ok, release}
        :skip -> fetch_github(endpoint, repo)
      end
    end
  end

  defp fetch_github(endpoint, repo),
    do: handle_response(request(endpoint, "application/vnd.github+json"), repo)

  # `:skip` whenever GitHub should answer instead — the leg is off, or it
  # failed in any way. Failures are logged at debug only: kilncms.dev being
  # down is not something an operator can act on, and the fallback covers it.
  defp fetch_feed(repo) do
    case feed_url() do
      {:ok, url} ->
        case fetch_feed_pages(feed_params(url), feed_origin(url), @feed_max_pages, []) do
          {:ok, entries} ->
            newest_feed_release(entries, repo)

          {:error, reason} ->
            Logger.debug("Kiln release feed failed, falling back to GitHub: #{inspect(reason)}")
            :skip
        end

      :disabled ->
        :skip

      {:error, :invalid_feed_url} ->
        Logger.warning(
          "KILN_UPDATE_FEED_URL is not an absolute http(s) URL; the update check is using GitHub only."
        )

        :skip
    end
  end

  # Exactly what the response needs and nothing more (#1877): the type filter,
  # the one attribute read below, and the page size. No version, host or
  # instance id — the feed's operator learns only that *a* Kiln asked.
  defp feed_params(url) do
    [
      url: url,
      params: [
        {"filter[type_name]", @feed_type},
        {"fields[entry]", "custom_fields"},
        {"page[limit]", @feed_page_size}
      ]
    ]
  end

  defp feed_origin(url) do
    uri = URI.parse(url)
    {uri.scheme, uri.host, uri.port}
  end

  # `links.next` is a full URL carrying the query (and the keyset cursor), so
  # it is requested as-is — but only on the feed's own origin. A `next` that
  # points elsewhere would send this instance's request, with its IP, to a
  # host the operator never configured, so it ends the walk instead.
  defp fetch_feed_pages(_target, _origin, 0, acc), do: {:ok, acc}

  defp fetch_feed_pages(target, origin, pages_left, acc) do
    case request(target, "application/vnd.api+json") do
      {:ok, %Req.Response{status: 200, body: %{"data" => data} = body}} when is_list(data) ->
        acc = acc ++ data

        case next_link(body, origin) do
          nil -> {:ok, acc}
          next -> fetch_feed_pages([url: next], origin, pages_left - 1, acc)
        end

      {:ok, %Req.Response{status: 200}} ->
        {:error, :unparseable_feed}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_link(%{"links" => %{"next" => next}}, origin) when is_binary(next) do
    if feed_origin(next) == origin, do: next
  end

  defp next_link(_body, _origin), do: nil

  # The highest final version wins. An entry that isn't a release this module
  # can stand behind — no version, an unparseable one, a pre-release — is
  # skipped rather than failing the whole feed; a feed with none left is a
  # failure, so GitHub answers. That is also the feed's state until the site
  # publishes its first release: an empty `data`.
  defp newest_feed_release(entries, repo) do
    case Enum.flat_map(entries, &feed_release(&1, repo)) do
      [] ->
        Logger.debug("Kiln release feed had no usable release, falling back to GitHub")
        :skip

      releases ->
        {:ok, Enum.max_by(releases, & &1.version, Version)}
    end
  end

  defp feed_release(
         %{"attributes" => %{"custom_fields" => %{"version" => raw} = fields}},
         repo
       )
       when is_binary(raw) do
    case Version.parse(raw |> String.trim() |> String.trim_leading("v")) do
      {:ok, %Version{pre: []} = version} ->
        tag = "v#{version}"

        [
          %{
            version: version,
            tag: tag,
            url: feed_release_url(fields["release_url"], tag, repo),
            published_at: parse_date(fields["released_on"]),
            highlights: parse_highlights(fields["highlights"])
          }
        ]

      _prerelease_or_unparseable ->
        []
    end
  end

  defp feed_release(_entry, _repo), do: []

  # The link is rendered as an `href` on the admin page, so only an http(s)
  # URL from the feed is used as-is; anything else (absent, `javascript:`)
  # becomes the configured repo's tag page.
  defp feed_release_url(url, tag, repo) when is_binary(url) do
    case validate_http_url(String.trim(url), :invalid) do
      {:ok, url} -> url
      {:error, :invalid} -> "#{@github_web}/#{repo}/releases/tag/#{tag}"
    end
  end

  defp feed_release_url(_url, tag, repo), do: "#{@github_web}/#{repo}/releases/tag/#{tag}"

  defp parse_date(raw) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
      _ -> nil
    end
  end

  defp parse_date(_raw), do: nil

  defp parse_highlights(raw) when is_binary(raw) do
    raw
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(@max_highlights)
    |> Enum.map(&String.slice(&1, 0, @max_highlight_length))
  end

  defp parse_highlights(_raw), do: []

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, repo),
    do: parse_release(body, repo)

  defp handle_response({:ok, %Req.Response{status: status}}, _repo),
    do: {:error, {:http_status, status}}

  defp handle_response({:error, reason}, _repo) do
    Logger.debug("Kiln update check failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp parse_release(%{"tag_name" => tag} = body, repo) do
    case Version.parse(String.trim_leading(tag, "v")) do
      # `releases/latest` never returns a release marked as a pre-release, so
      # a `-rc.1` here is a candidate published without `--prerelease`. It is
      # not a release anyone should be told to move to, and the final release
      # it displaced as "latest" is not in this response to compare against —
      # so say nothing rather than "behind" or "up to date" (#1541).
      {:ok, %Version{pre: [_ | _]}} ->
        {:error, :prerelease}

      {:ok, version} ->
        {:ok,
         %{
           version: version,
           tag: tag,
           url: body["html_url"] || "#{@github_web}/#{repo}/releases",
           published_at: parse_timestamp(body["published_at"]),
           highlights: []
         }}

      :error ->
        {:error, :unparseable_release}
    end
  end

  defp parse_release(_body, _repo), do: {:error, :unparseable_release}

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  # One request shape for both legs, so neither can drift into sending more:
  # an accept header and the bare `KilnCMS` user-agent — no version, no host,
  # no instance id. `target` is a URL or Req options carrying one.
  defp request(target, accept) when is_binary(target), do: request([url: target], accept)

  defp request(target, accept) do
    [
      headers: [
        {"accept", accept},
        {"user-agent", "KilnCMS"}
      ],
      # An admin is waiting on the page render; fail fast rather than retry.
      receive_timeout: 10_000,
      retry: false
    ]
    |> Keyword.merge(target)
    |> Keyword.merge(req_options())
    |> Req.request()
  end

  defp req_options do
    Application.get_env(:kiln_cms, __MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
