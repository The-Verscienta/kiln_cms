defmodule Kiln.Plugins.Health do
  @moduledoc """
  Whether the installed plugins are still what they should be (#2244): the
  package each was built from still matches hex.pm, no security notice covers
  the installed version, the release is not retired or long abandoned, and
  its `kiln_plugin` requirement accepts the SDK this core bundles.

  The comparison itself is pure (`Kiln.Plugins.Health.Evaluate`); this module
  gathers the inputs and caches them, following `Kiln.Updates`:

    * `check/1` fetches when the cache is cold (or `force: true`, floored at
      one request round per minute) and returns a `Kiln.Plugins.Health.Report`;
    * `cached/1` **never touches the network** — it answers from the cache,
      or `nil` on a miss — so a page that must not wait (Security posture)
      reads it and calls `warm/0` on a miss;
    * `warm/0` starts one background `check/1`, at most one in flight per node.

  Only the fetched data is cached, never the verdict: every read re-evaluates
  it against the current time, so staleness does not freeze at fetch time.
  Hex's answers are kept in `:persistent_term` for 24 hours when every request
  answered and 15 minutes when any failed, the notices in
  `Kiln.SecurityNotices`'s cache on the same terms, and both die with the VM. Nothing is
  persisted: no table, no Oban job, no request at boot.

  ## What is asked, and when

  Only when a platform admin opens System or Security posture with a cold
  cache (or presses "Check plugins now"), and only when some plugin comes from
  Hex, git or a path — a deployment whose plugins are all built from this
  project (or that has none) makes no request at all. Then:

    * for each plugin locked from hex.pm: two GETs to hex.pm
      (`Kiln.Plugins.Health.Hex`), which tell hex.pm the plugin's package name
      and version;
    * one GET (more if it pages) to the security notices feed
      (`Kiln.SecurityNotices`, which caches it and shares it with the core's
      own notices check), which sends nothing about this installation.

  Both go through `KilnCMS.SafeFetch` with a bare `KilnCMS` user-agent.

  ## Configuration

  `config :kiln_cms, Kiln.Plugins.Health` — see `config/runtime/updates.exs`:

    * `:enabled` — unset follows `Kiln.Updates.enabled?/0`, so
      `KILN_UPDATE_CHECK=false` turns this off too; `KILN_PLUGIN_HEALTH_CHECK`
      overrides it either way;
    * `:stale_after_months` — default 24 (`KILN_PLUGIN_STALE_MONTHS`);
    * `:hex_api_url`, `:req_options` — for tests and mirrors.

  The notices feed's own settings (`KILN_SECURITY_NOTICES_URL`) are
  `Kiln.SecurityNotices`'s; see `Kiln.SecurityNotices.url/0`.

  Unknown is never reported as OK: an unreachable Hex or feed makes the
  affected plugins `:unknown`.
  """

  require Logger

  alias Kiln.Plugins.Health.Evaluate
  alias Kiln.Plugins.Health.Hex
  alias Kiln.Plugins.Health.Installed
  alias Kiln.Plugins.Health.PluginStatus
  alias Kiln.Plugins.Health.Report
  alias Kiln.SecurityNotices

  @cache_key {__MODULE__, :hex}
  @force_key {__MODULE__, :last_forced_at}
  @ttl_ms :timer.hours(24)
  @error_ttl_ms :timer.minutes(15)
  @min_force_interval_ms :timer.seconds(60)

  @default_hex_api_url "https://hex.pm/api"
  @default_stale_after_months 24

  # Per-package budget: two requests of up to 10 s each, plus slack.
  @hex_timeout_ms 25_000
  @hex_concurrency 4
  # `Kiln.SecurityNotices` bounds its own request at 60 s, but a caller that
  # waited on another's request (one in flight per node) can return up to
  # ~8 s after it, `:global`'s back-off between lock attempts; this leaves
  # room for both.
  @notices_timeout_ms 75_000

  @warmer Module.concat(__MODULE__, Warmer)

  @doc """
  The health of every installed plugin.

  Answers from the cache when it holds a fresh fetch, otherwise fetches. Never
  makes a request when checks are disabled (`state: :disabled`, with the local
  SDK check still run) or when no plugin comes from Hex, git or a path
  (`state: :nothing_to_check`).

  Options: `force: true` bypasses the cache, at most once a minute (a forced
  call inside the floor is served from the cache like any other); `:installed`
  and `:now` are test seams.
  """
  @spec check(keyword()) :: Report.t()
  def check(opts \\ []) do
    installed = Keyword.get_lazy(opts, :installed, &Installed.all/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    cond do
      not enabled?() -> local_report(installed, now, :disabled)
      not dependency_plugins?(installed) -> local_report(installed, now, :nothing_to_check)
      opts[:force] -> forced_check(installed, now)
      entry = cached_entry(installed) -> report(installed, entry, cached_notices(), now)
      true -> fetch_and_report(installed, now, false)
    end
  end

  @doc """
  What `check/1` would answer from the cache, **without touching the network**:
  a report, or `nil` when nothing fresh is cached. A disabled check and a
  deployment with nothing to check answer a report, since neither needs a
  request. Takes the same `:installed` and `:now` seams as `check/1`.
  """
  @spec cached(keyword()) :: Report.t() | nil
  def cached(opts \\ []) do
    installed = Keyword.get_lazy(opts, :installed, &Installed.all/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    cond do
      not enabled?() -> local_report(installed, now, :disabled)
      not dependency_plugins?(installed) -> local_report(installed, now, :nothing_to_check)
      entry = cached_entry(installed) -> report(installed, entry, cached_notices(), now)
      true -> nil
    end
  end

  @doc """
  Fill the cache in the background: one non-forced `check/1` in a supervised
  task, for a caller that must not wait. Answers `:started`, `:in_flight`,
  `:cached`, `:disabled` or `:nothing_to_check`.
  """
  @spec warm() :: :started | :in_flight | :cached | :disabled | :nothing_to_check
  def warm do
    installed = Installed.all()

    cond do
      not enabled?() -> :disabled
      not dependency_plugins?(installed) -> :nothing_to_check
      cached_entry(installed) -> :cached
      Process.whereis(@warmer) -> :in_flight
      true -> start_warmer()
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
    if register_warmer(), do: check()
  end

  defp register_warmer do
    Process.register(self(), @warmer)
  rescue
    # `register/2` raises when the name is taken: another warmer is running.
    ArgumentError -> false
  end

  @doc """
  Whether plugin checks run. An explicit `:enabled` wins
  (`KILN_PLUGIN_HEALTH_CHECK`); otherwise this follows the update check, so
  an operator who turned that off for "no outbound requests" gets none from
  here either.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Keyword.fetch(config(), :enabled) do
      {:ok, enabled} when is_boolean(enabled) -> enabled
      _unset -> Kiln.Updates.enabled?()
    end
  end

  @doc "Months without a release on Hex after which a plugin reads as stale (default 24)."
  @spec stale_after_months() :: pos_integer()
  def stale_after_months do
    case Keyword.get(config(), :stale_after_months) do
      months when is_integer(months) and months > 0 -> months
      _unset -> @default_stale_after_months
    end
  end

  @doc "The `kiln_plugin` version this core bundles, or `nil` if it cannot be read."
  @spec sdk_version() :: String.t() | nil
  def sdk_version do
    case Application.spec(:kiln_plugin, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  @doc false
  # Test seam: start from a known cache state.
  # The notices cache is cleared too: it is this check's other half.
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :persistent_term.erase(@force_key)
    SecurityNotices.clear_cache()
  end

  @doc false
  # Test seam: cache `fetched` as if a check had just fetched it — Hex's half
  # here, the notices in `Kiln.SecurityNotices`.
  @spec put_cache(Evaluate.fetched()) :: :ok
  def put_cache(%{hex: hex, notices: notices}) do
    _ = store(hex)
    if notices != :disabled, do: SecurityNotices.put_cache(notices)
    :ok
  end

  @doc false
  # Test seam: the name a running warmer is registered under.
  @spec warmer_name() :: atom()
  def warmer_name, do: @warmer

  # ---------------------------------------------------------------------------

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])

  # Built from this project or not in any app: nothing upstream to ask about.
  defp dependency_plugins?(installed),
    do: Enum.any?(installed, &(&1.source in [:hex, :git, :path]))

  defp local_report(installed, now, state) do
    %Report{
      plugins:
        Evaluate.evaluate(installed, %{hex: :disabled, notices: :disabled}, eval_opts(now)),
      checked_at: nil,
      state: state,
      notices: :disabled
    }
  end

  defp forced_check(installed, now) do
    mono = System.monotonic_time(:millisecond)
    last = :persistent_term.get(@force_key, nil)

    if last && mono - last < @min_force_interval_ms do
      case cached_entry(installed) do
        nil -> fetch_and_report(installed, now, false)
        entry -> report(installed, entry, cached_notices(), now)
      end
    else
      :persistent_term.put(@force_key, mono)
      fetch_and_report(installed, now, true)
    end
  end

  # The notices this read uses are the ones just fetched, so a fetch that
  # timed out on this side reads `{:error, :timeout}` for this read only.
  defp fetch_and_report(installed, now, force?) do
    %{hex: hex, notices: notices} = fetch(installed, force?)
    entry = store(hex)
    report = report(installed, entry, notices, now)
    warn_on_failures(report)
    report
  end

  defp report(installed, entry, notices, now) do
    fetched = %{hex: entry.hex, notices: notices}

    %Report{
      plugins: Evaluate.evaluate(installed, fetched, eval_opts(now)),
      checked_at: older(entry.checked_at, SecurityNotices.checked_at()),
      state: if(entry.ok? and notices_answered?(notices), do: :fresh, else: :partial),
      notices: notices_state(notices)
    }
  end

  defp cached_notices, do: SecurityNotices.cached() || {:error, :not_fetched}

  defp older(hex_at, nil), do: hex_at
  defp older(hex_at, notices_at), do: Enum.min([hex_at, notices_at], DateTime)

  defp notices_answered?(notices), do: match?({:ok, _}, notices) or notices == :disabled

  defp notices_state({:ok, _notices}), do: :ok
  defp notices_state(:disabled), do: :disabled
  defp notices_state(_failed), do: :unknown

  defp eval_opts(now) do
    [now: now, stale_after_months: stale_after_months(), sdk_version: sdk_version()]
  end

  # A cached fetch serves only if it covers every hex.pm plugin installed now,
  # and the notices cache still answers (or there is no feed to ask): a hit
  # here never reads notices as unfetched.
  defp cached_entry(installed) do
    with {stored_at, entry} <- :persistent_term.get(@cache_key, nil),
         true <- System.monotonic_time(:millisecond) - stored_at < ttl(entry),
         true <- covers?(entry.hex, installed),
         true <- SecurityNotices.cached() != nil do
      entry
    else
      _miss -> nil
    end
  end

  defp covers?(hex, installed) when is_map(hex),
    do: Enum.all?(hex_targets(installed), &Map.has_key?(hex, &1.package))

  defp covers?(_disabled, _installed), do: false

  defp ttl(%{ok?: true}), do: @ttl_ms
  defp ttl(_entry), do: @error_ttl_ms

  defp store(hex) do
    entry = %{hex: hex, checked_at: DateTime.utc_now(), ok?: all_answered?(hex)}
    :persistent_term.put(@cache_key, {System.monotonic_time(:millisecond), entry})
    entry
  end

  # A 404 is an answer; every other error is a failure and gets the short TTL.
  defp all_answered?(hex) do
    hex == :disabled or
      Enum.all?(Map.values(hex), &(match?({:ok, _}, &1) or &1 == {:error, :not_found}))
  end

  defp hex_targets(installed) do
    installed
    |> Enum.filter(&(&1.source == :hex and &1.repo == "hexpm"))
    |> Enum.uniq_by(& &1.package)
  end

  # The fetch tasks are linked to the caller (a LiveView, the warmer, or a Mix
  # task that has no supervisor to lean on), so each body turns its own crash
  # into an error: a crash is a source that did not answer — unknown — and must
  # never take the caller down with it.
  defp guarded(fun) do
    fun.()
  rescue
    exception -> {:error, {:crashed, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:crashed, kind}}
  end

  defp fetch(installed, force?) do
    notices = Task.async(fn -> guarded(fn -> SecurityNotices.fetch(force: force?) end) end)
    hex = fetch_hex(hex_targets(installed))

    notices =
      case Task.yield(notices, @notices_timeout_ms) || Task.shutdown(notices, :brutal_kill) do
        {:ok, result} -> result
        _timeout -> {:error, :timeout}
      end

    %{hex: hex, notices: notices}
  end

  defp fetch_hex(targets) do
    opts = [base_url: hex_api_url(), req_options: req_options()]

    targets
    |> Task.async_stream(
      fn target -> guarded(fn -> Hex.fetch(target.package, target.version, opts) end) end,
      max_concurrency: @hex_concurrency,
      timeout: @hex_timeout_ms,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(targets)
    |> Map.new(fn
      {{:ok, result}, target} -> {target.package, result}
      {{:exit, _reason}, target} -> {target.package, {:error, :timeout}}
    end)
  end

  defp hex_api_url, do: Keyword.get(config(), :hex_api_url, @default_hex_api_url)
  defp req_options, do: Keyword.get(config(), :req_options, [])

  # One line per freshly fetched check that found a failing plugin, so an
  # operator who never opens the page still has it in the logs. Alerting is
  # #2245's.
  defp warn_on_failures(%Report{plugins: plugins}) do
    case Enum.filter(plugins, &(&1.overall == :fail)) do
      [] ->
        :ok

      failing ->
        Logger.warning(
          "Plugin health check failed for: " <>
            Enum.map_join(failing, "; ", &"#{&1.name} (#{Enum.join(fail_kinds(&1), ", ")})")
        )
    end
  end

  defp fail_kinds(%PluginStatus{} = status) do
    [
      match?({:mismatch, _}, status.integrity) && "changed on Hex since this build",
      Enum.any?(elem(status.advisories, 1), &(&1.severity in [:high, :critical, :unknown])) &&
        "security notice",
      Enum.any?(status.abandonment, &match?({:retired, :security, _}, &1)) &&
        "retired for security"
    ]
    |> Enum.filter(&is_binary/1)
  end
end
