defmodule Kiln.SecurityNotices do
  @moduledoc """
  The security notices kilncms.dev publishes (#1873), fetched once and shared
  by everything that reads them: the plugin health check
  (`Kiln.Plugins.Health`, #2244) and the core's own notices (#2522).

  This module owns where the feed is (`url/0`), the cache, and the rule that
  at most one request round is in flight per node. It is **not** an on/off
  switch: it does not read `KILN_UPDATE_CHECK` or `KILN_PLUGIN_HEALTH_CHECK`
  itself. Each caller gates on its own switch before calling `fetch/1` or
  `warm/0`; a `:disabled` here only means there is no feed to ask (turned
  off, or a fork or mirror that names none).

    * `fetch/1` answers from the cache when it holds a fresh answer, and
      otherwise asks the feed (`force: true` skips the cache, at most once a
      minute);
    * `cached/0` **never touches the network**: the cached answer, or `nil`
      on a miss;
    * `warm/0` starts one background `fetch/1`, at most one per node.

  Every answer is cached, failures included, in one `:persistent_term` entry:
  24 hours for a list of notices and 15 minutes for an error, so an outage
  cannot turn page loads into a request stream. It dies with the VM; nothing
  is persisted and nothing is asked at boot.

  The request itself is `Kiln.Plugins.Health.Notices.fetch/2`: a GET of the
  published `security_notice` entries (more if it pages, same origin only)
  through `KilnCMS.SafeFetch`, with a bare `KilnCMS` user-agent and nothing
  about this installation.

  ## Configuration

  `config :kiln_cms, Kiln.SecurityNotices` — see `config/runtime/updates.exs`:

    * `:url` — see `url/0` (`KILN_SECURITY_NOTICES_URL`);
    * `:type`, `:req_options` — the content type filtered on (default
      `"security_notice"`) and options for the HTTP client; for tests and
      mirrors.
  """

  require Logger

  alias Kiln.Plugins.Health.Notice
  alias Kiln.Plugins.Health.Notices
  alias Kiln.SecurityNotices.Core

  @cache_key {__MODULE__, :result}
  @force_key {__MODULE__, :last_forced_at}
  @ttl_ms :timer.hours(24)
  @error_ttl_ms :timer.minutes(15)
  @min_force_interval_ms :timer.seconds(60)

  @default_url "https://kilncms.dev/api/json/entries/published"
  @default_type "security_notice"

  # Up to five feed pages of up to 10 s each, plus slack.
  @fetch_timeout_ms 60_000

  @warmer Module.concat(__MODULE__, Warmer)

  @type result :: {:ok, [Notice.t()]} | {:error, term()}

  @doc """
  The security notices feed, or `:disabled`.

    * `KILN_SECURITY_NOTICES_URL=false` (any off-spelling) — `:disabled`;
    * `KILN_SECURITY_NOTICES_URL=<url>` — that published-entries endpoint;
    * unset — `#{@default_url}`, but only while the update check's release
      feed is kilncms.dev's own (`Kiln.Updates.feed_url/0`). A fork
      (`KILN_UPDATE_REPO`), a mirror (`KILN_UPDATE_RELEASES_URL`) or
      `KILN_UPDATE_FEED_URL=false` turns that feed off, and this follows it,
      so an operator who kept kilncms.dev out does not find it reached from
      here.

  A configured value that isn't an absolute http(s) URL is
  `{:error, :invalid_notices_url}`, and the notices then read as unknown.
  """
  @spec url() :: {:ok, String.t()} | :disabled | {:error, :invalid_notices_url}
  def url do
    case Keyword.get(config(), :url) do
      false -> :disabled
      url when is_binary(url) -> configured_url(String.trim(url))
      _unset -> default_url()
    end
  end

  defp configured_url(""), do: default_url()

  defp configured_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ~w(http https) and is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, :invalid_notices_url}
    end
  end

  defp default_url do
    if Kiln.Updates.feed_url() == {:ok, @default_url},
      do: {:ok, @default_url},
      else: :disabled
  end

  @doc """
  The published notices: from the cache when it holds a fresh answer,
  otherwise from the feed. `:disabled` (and no request) when `url/0` is;
  `{:error, :invalid_notices_url}` (logged, no request) when it is invalid.

  Concurrent callers on one node share one request: the first asks, the rest
  wait for it and read what it stored. Whatever the feed answers is stored,
  failures included, so the next caller does not ask again.

  Options: `force: true` skips the cache, at most once a minute (a forced
  call inside that floor is served from the cache like any other).
  `:timeout` (milliseconds, default 60 s) bounds the wait on the feed; a test
  seam.
  """
  @spec fetch(keyword()) :: result() | :disabled
  def fetch(opts \\ []) do
    case url() do
      {:ok, url} ->
        force? = Keyword.get(opts, :force, false) == true
        timeout = Keyword.get(opts, :timeout, @fetch_timeout_ms)
        (not force? && fresh(url)) || single_flight(url, force?, timeout)

      :disabled ->
        :disabled

      {:error, :invalid_notices_url} = error ->
        Logger.warning(
          "KILN_SECURITY_NOTICES_URL is not an absolute http(s) URL; security notices are unknown."
        )

        error
    end
  end

  # One fetch per node at a time. The cache is re-read inside the lock, so a
  # caller that waited on another's request reads its answer instead of
  # asking again; the force floor is checked and set inside it too, so two
  # forced calls at once make one request. `:global.trans/3` on this node only
  # needs no running application (a Mix task calls this) and is released if
  # the holder dies. A waiter retries with a random back-off that grows to
  # about 8 s, so it can return up to that long after the holder's answer:
  # callers that bound their wait (`Kiln.Plugins.Health`) leave room for it.
  defp single_flight(url, force?, timeout) do
    :global.trans(
      {{__MODULE__, :fetch}, self()},
      fn -> locked_fetch(url, force?, timeout) end,
      [node()]
    )
  end

  defp locked_fetch(url, false, timeout), do: fresh(url) || fetch_and_store(url, timeout)

  defp locked_fetch(url, true, timeout) do
    mono = System.monotonic_time(:millisecond)
    last = :persistent_term.get(@force_key, nil)

    if last && mono - last < @min_force_interval_ms do
      locked_fetch(url, false, timeout)
    else
      :persistent_term.put(@force_key, mono)
      fetch_and_store(url, timeout)
    end
  end

  # The request runs in a task so a slow feed is bounded and a crash is an
  # answer ("did not answer"), never the caller's crash: the caller is a
  # LiveView, a warmer or a Mix task. Every outcome is stored.
  defp fetch_and_store(url, timeout) do
    task =
      Task.async(fn ->
        guarded(fn -> Notices.fetch(url, type: type(), req_options: req_options()) end)
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _timeout -> {:error, :timeout}
      end

    stored = store(url, result)
    warn_if_core_affected(stored)
    stored
  end

  # Logged here, where a fresh answer is stored, so it is said once per fetch
  # rather than on every page read the cache then serves. Ids only: nothing
  # from a notice's prose or links reaches the log. Gated on the update check,
  # as the posture check that owns the core's verdict is.
  defp warn_if_core_affected({:ok, notices}) do
    with true <- Kiln.Updates.enabled?(),
         {:ok, %{affected: [_ | _] = affected, version: version}} <-
           Core.status(notices, Kiln.Version.version()) do
      Logger.warning(
        "Kiln #{version} is covered by security notice(s) " <>
          "#{Enum.map_join(affected, ", ", & &1.id)}; update it (System, Updates)."
      )
    end

    :ok
  end

  defp warn_if_core_affected(_failed), do: :ok

  defp guarded(fun) do
    fun.()
  rescue
    exception -> {:error, {:crashed, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:crashed, kind}}
  end

  @doc """
  What `fetch/1` would answer from the cache, **without touching the
  network**: the cached answer, `:disabled` or
  `{:error, :invalid_notices_url}` (neither needs a request), or `nil` when
  nothing fresh is cached.
  """
  @spec cached() :: result() | :disabled | nil
  def cached do
    case url() do
      {:ok, url} -> fresh(url)
      other -> other
    end
  end

  @doc """
  When the cached answer was fetched, or `nil` when nothing fresh is cached.
  """
  @spec checked_at() :: DateTime.t() | nil
  def checked_at do
    with {:ok, url} <- url(),
         {_result, checked_at} <- fresh_entry(url) do
      checked_at
    else
      _miss -> nil
    end
  end

  @doc """
  Fill the cache in the background: one non-forced `fetch/1` in a supervised
  task, for a caller that must not wait. Answers `:started`, `:in_flight`
  (one is already running), `:cached` (`cached/0` already answers, an invalid
  URL included) or `:disabled`.
  """
  @spec warm() :: :started | :in_flight | :cached | :disabled
  def warm do
    case cached() do
      :disabled -> :disabled
      nil -> if Process.whereis(@warmer), do: :in_flight, else: start_warmer()
      _answer -> :cached
    end
  end

  defp start_warmer do
    case Task.Supervisor.start_child(KilnCMS.TaskSupervisor, &warm_once/0) do
      {:ok, _pid} -> :started
      {:error, _full} -> :in_flight
    end
  end

  # The registered name is the one-in-flight guard, as in `Kiln.Updates`.
  defp warm_once do
    if register_warmer(), do: fetch()
  end

  defp register_warmer do
    Process.register(self(), @warmer)
  rescue
    # `register/2` raises when the name is taken: another warmer is running.
    ArgumentError -> false
  end

  @doc false
  # Test seam: start from a known cache state.
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :persistent_term.erase(@force_key)
    :ok
  end

  @doc false
  # Test seam: cache `result` for the current URL as if a fetch had just
  # stored it. Nothing is stored when there is no URL to ask.
  @spec put_cache(result()) :: :ok
  def put_cache(result) do
    with {:ok, url} <- url(), do: store(url, result)
    :ok
  end

  @doc false
  # Test seam: the name a running warmer is registered under.
  @spec warmer_name() :: atom()
  def warmer_name, do: @warmer

  # ---------------------------------------------------------------------------

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])

  defp type, do: Keyword.get(config(), :type, @default_type)
  defp req_options, do: Keyword.get(config(), :req_options, [])

  defp fresh(url) do
    case fresh_entry(url) do
      {result, _checked_at} -> result
      nil -> nil
    end
  end

  # An answer serves only the URL it came from, so changing the URL (or a
  # test switching it) never reads another feed's notices.
  defp fresh_entry(url) do
    case :persistent_term.get(@cache_key, nil) do
      {^url, stored_at, checked_at, result} ->
        if System.monotonic_time(:millisecond) - stored_at < ttl(result),
          do: {result, checked_at}

      _miss ->
        nil
    end
  end

  defp ttl({:ok, _notices}), do: @ttl_ms
  defp ttl(_error), do: @error_ttl_ms

  defp store(url, result) do
    entry = {url, System.monotonic_time(:millisecond), DateTime.utc_now(), result}
    :persistent_term.put(@cache_key, entry)
    result
  end
end
