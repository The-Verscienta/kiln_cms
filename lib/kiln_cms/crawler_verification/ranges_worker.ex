defmodule KilnCMS.CrawlerVerification.RangesWorker do
  @moduledoc """
  Fetches every search engine's published crawler range list (#2586),
  installs each one this node accepts, and sends it to the other nodes
  (`KilnCMS.CrawlerVerification.Ranges`, `KilnCMS.CrawlerVerification.RangesSync`).

  Scheduled from `KilnCMS.Application` (`KILN_CRAWLER_RANGES_CRON`, every 6
  hours by default), so one node fetches per run, and queued by a node that
  finds a list not fresh shortly after boot or at its 10-minute check
  (`KilnCMS.CrawlerVerification.RangesSync`); such a job names only the
  stale engines (`%{"engines" => [...]}`). With ranges off
  (`KILN_CRAWLER_RANGES=false`, or verification off) it makes **no request**.

  Every fetch goes through `KilnCMS.SafeFetch`: pinned, HTTPS, no redirects
  followed, at most `:max_bytes` read. A list the parser refuses, a non-200
  answer or a failed request keeps the list held before, with its old age,
  so it goes stale rather than being replaced by something worse. Every
  vendor is tried even when one fails, and a failure is telemetry and one
  log line naming the engines, not a failed job: the job completes, and the
  next run tries again.

  Queued on `:default` with `max_attempts: 1`, and unique for 10 minutes by
  worker alone, whatever it asks for and however the last run ended, so the
  nodes and the cron queue at most one job per 10 minutes between them.

  ## Telemetry

  `[:kiln_cms, :crawler_verification, :ranges_fetch]`, `%{count: 1}`,
  `%{engine, result}`, one per vendor per run. `result` is `:ok`,
  `:http_error`, `:transport_error`, `:too_large`, `:blocked`, `:invalid`,
  `:no_prefixes`, `:too_many`, `:too_broad`, `:not_public` or `:other`.
  """
  # Unique by worker alone (`keys: []`), over every state: a run that ended
  # `discarded` or `completed` still holds the 10 minutes, so a vendor that
  # keeps failing cannot turn every node's 10-minute check into a fresh fetch
  # of all four lists (#2586 review).
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: 600, keys: [], states: Oban.Job.states()]

  require Logger

  alias KilnCMS.CrawlerVerification.Engines
  alias KilnCMS.CrawlerVerification.Ranges
  alias KilnCMS.CrawlerVerification.Ranges.Parser

  @type result ::
          :ok
          | :disabled
          | :http_error
          | :transport_error
          | :too_large
          | :blocked
          | :invalid
          | :other
          | Parser.error()

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if Ranges.enabled?() do
      config = Ranges.config()

      case Enum.reject(engines(args), &(refresh(&1, config) == :ok)) do
        [] ->
          :ok

        failed ->
          Logger.warning(
            "Crawler verification: could not refresh the published crawler IP ranges of " <>
              "#{Enum.join(failed, ", ")}; each keeps the list held before until it goes stale"
          )

          :ok
      end
    else
      :ok
    end
  end

  # The engines a job names (`"engines"`, from `RangesSync`'s check of the
  # stale ones), or every engine with a source (the cron's job). A name that
  # is not a current range engine is dropped, never turned into an atom.
  defp engines(%{"engines" => names}) when is_list(names) do
    Enum.filter(Engines.range_engines(), &(Atom.to_string(&1) in names))
  end

  defp engines(_args), do: Engines.range_engines()

  @doc """
  Fetches, checks and installs `engine`'s list, and sends it to the other
  nodes. Answers the result telemetry reports.

  With ranges off (`KILN_CRAWLER_RANGES=false`, or verification off) it
  answers `:disabled` and does nothing else: no request, no telemetry, no
  list installed or sent (#2853). The switch is read from the application
  environment, never from `config`, so no caller can pass its way past it.
  """
  @spec refresh(atom(), keyword()) :: result()
  def refresh(engine, config \\ Ranges.config()) do
    if Ranges.enabled?() do
      result =
        with {:ok, body} <- fetch(Engines.range_source(engine), config),
             {:ok, cidrs} <- parse(body, config) do
          Ranges.put(engine, cidrs)
          Ranges.broadcast(engine)
          :ok
        end

      report(engine, result)
      result
    else
      :disabled
    end
  end

  defp fetch(nil, _config), do: :other

  defp fetch(url, config) do
    case KilnCMS.SafeFetch.get(url,
           headers: [{"accept", "application/json"}, {"user-agent", "KilnCMS"}],
           max_bytes: config[:max_bytes],
           receive_timeout: 10_000,
           req_options: config[:req_options] || []
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: _status}} -> :http_error
      {:error, reason} -> classify(reason)
    end
  end

  # `SafeFetch` answers its errors as text. Matched by the prefixes it
  # writes today, and anything else is `:other`, so a reworded message costs
  # a telemetry tag, never a crash.
  defp classify(reason) when is_binary(reason) do
    cond do
      String.starts_with?(reason, "blocked") -> :blocked
      String.starts_with?(reason, "response exceeded") -> :too_large
      String.starts_with?(reason, "request failed") -> :transport_error
      true -> :other
    end
  end

  defp parse(body, config) do
    case Parser.parse(body, max_prefixes: config[:max_prefixes]) do
      {:ok, cidrs} -> {:ok, cidrs}
      {:error, :invalid_json} -> :invalid
      {:error, reason} -> reason
    end
  end

  defp report(engine, result) do
    :telemetry.execute(
      [:kiln_cms, :crawler_verification, :ranges_fetch],
      %{count: 1},
      %{engine: engine, result: result}
    )
  end
end
