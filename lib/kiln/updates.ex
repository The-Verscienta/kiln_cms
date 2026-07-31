defmodule Kiln.Updates do
  @moduledoc """
  Whether a newer Kiln release exists upstream.

  This is the *reporting* half of the update story; `mix kiln.update` is the
  half that changes anything. A deployed instance runs from an immutable image
  built off a pinned submodule (see `projects/README.md`), so it cannot update
  itself — it can only tell an admin that it's behind and print the command.

  ## Why the API and not git

  `mix kiln.update` reads tags from the checkout it runs in. A running
  container has no checkout, so this module asks the GitHub releases API
  instead. The two therefore agree only once a tag has an accompanying
  *release* — which is the point of the release checklist in `docs/releasing.md`.

  ## Which upstream

  Whichever one this deployment was told, via `repo/0` and `releases_url/0` —
  defaulting to the canonical repo, but *only* as a default. A fork that keeps
  comparing itself against `The-Verscienta/kiln_cms` gets an answer about
  someone else's code: behind upstream it nags forever about a release its
  codebase does not contain, and ahead of upstream `compare/2` reads `:gt` and
  reports "Up to date" indefinitely, so the fork's own security releases never
  surface.

  ## Network behaviour

  One unauthenticated GET to the releases API, made only when an admin opens
  the update page. It is a public read of the configured repo's releases: the
  request carries a bare `KilnCMS` user-agent and no version, no instance
  identifier and no content, so nothing about this deployment is disclosed.
  Operators who still want no outbound traffic at all set
  `KILN_UPDATE_CHECK=false`, and `check/1` then reports `:disabled` without
  touching the network.

  Every outcome is cached in `:persistent_term` — 24h for a comparison, 15
  minutes for a failure — and forced checks are floored at one per minute.
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
    * `{:error, reason}` — the check itself failed (offline, rate-limited).
  """
  @type result ::
          {:ok, :current}
          | {:ok, {:behind, release()}}
          | {:error,
             :disabled | :unknown_version | :invalid_repo | :invalid_releases_url | term()}

  @type release :: %{
          version: Version.t(),
          tag: String.t(),
          url: String.t(),
          published_at: DateTime.t() | nil
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
  # malformed should fail closed rather than be silently unused.
  defp fetch_latest do
    with {:ok, repo} <- repo(),
         {:ok, endpoint} <- releases_url(repo) do
      handle_response(request(endpoint), repo)
    end
  end

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
      {:ok, version} ->
        {:ok,
         %{
           version: version,
           tag: tag,
           url: body["html_url"] || "#{@github_web}/#{repo}/releases",
           published_at: parse_timestamp(body["published_at"])
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

  defp request(url) do
    [
      url: url,
      headers: [
        {"accept", "application/vnd.github+json"},
        {"user-agent", "KilnCMS"}
      ],
      # An admin is waiting on the page render; fail fast rather than retry.
      receive_timeout: 10_000,
      retry: false
    ]
    |> Keyword.merge(req_options())
    |> Req.request()
  end

  defp req_options do
    Application.get_env(:kiln_cms, __MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
