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

  ## Network behaviour

  One unauthenticated GET to api.github.com, made only when an admin opens the
  update page. It is a public read of the upstream repo's releases: the request
  carries a bare `KilnCMS` user-agent and no version, no instance identifier
  and no content, so nothing about this deployment is disclosed. Operators who
  still want no outbound traffic at all set `KILN_UPDATE_CHECK=false`, and
  `check/1` then reports `:disabled` without touching the network.

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

  @releases_url "https://api.github.com/repos/The-Verscienta/kiln_cms/releases/latest"

  @typedoc """
  The outcome of an upstream check.

    * `{:ok, :current}` — running the newest release, or newer than it;
    * `{:ok, {:behind, release}}` — a newer release exists;
    * `{:error, :disabled}` — the operator turned checks off;
    * `{:error, :unknown_version}` — this build's version doesn't parse, so no
      comparison is meaningful;
    * `{:error, reason}` — the check itself failed (offline, rate-limited).
  """
  @type result ::
          {:ok, :current}
          | {:ok, {:behind, release()}}
          | {:error, :disabled | :unknown_version | term()}

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
  def pin_path do
    Application.get_env(:kiln_cms, __MODULE__, [])
    |> Keyword.get(:pin_path)
    |> normalize_pin_path()
  end

  defp normalize_pin_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_pin_path(_path), do: nil

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

  defp fetch_latest do
    case request() do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_release(body)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.debug("Kiln update check failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_release(%{"tag_name" => tag} = body) do
    case Version.parse(String.trim_leading(tag, "v")) do
      {:ok, version} ->
        {:ok,
         %{
           version: version,
           tag: tag,
           url: body["html_url"] || "https://github.com/The-Verscienta/kiln_cms/releases",
           published_at: parse_timestamp(body["published_at"])
         }}

      :error ->
        {:error, :unparseable_release}
    end
  end

  defp parse_release(_body), do: {:error, :unparseable_release}

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp request do
    [
      url: @releases_url,
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
