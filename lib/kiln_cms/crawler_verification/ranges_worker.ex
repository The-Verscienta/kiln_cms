defmodule KilnCMS.CrawlerVerification.RangesWorker do
  @moduledoc """
  Fetches every search engine's published crawler range list (#2586),
  installs each one this node accepts, and sends it to the other nodes
  (`KilnCMS.CrawlerVerification.Ranges`, `KilnCMS.CrawlerVerification.RangesSync`).

  Scheduled from `KilnCMS.Application` (`KILN_CRAWLER_RANGES_CRON`, every 6
  hours by default), so one node fetches per run, and queued once more by a
  node that finds no fresh list shortly after boot. With ranges off
  (`KILN_CRAWLER_RANGES=false`, or verification off) it makes **no request**.

  Every fetch goes through `KilnCMS.SafeFetch`: pinned, HTTPS, no redirects
  followed, at most `:max_bytes` read. A list the parser refuses, a non-200
  answer or a failed request keeps the list held before, with its old age,
  so it goes stale rather than being replaced by something worse. Every
  vendor is tried even when one fails; the job then answers an error naming
  the failed engines, and the next run tries again.

  Queued on `:default`, `max_attempts: 1` and unique for 10 minutes, so
  nodes booting together and the cron queue one job between them.

  ## Telemetry

  `[:kiln_cms, :crawler_verification, :ranges_fetch]`, `%{count: 1}`,
  `%{engine, result}`, one per vendor per run. `result` is `:ok`,
  `:http_error`, `:transport_error`, `:too_large`, `:blocked`, `:invalid`,
  `:no_prefixes`, `:too_many`, `:too_broad`, `:not_public` or `:other`.
  """
  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 600]

  require Logger

  alias KilnCMS.CrawlerVerification.Engines
  alias KilnCMS.CrawlerVerification.Ranges
  alias KilnCMS.CrawlerVerification.Ranges.Parser

  @type result ::
          :ok
          | :http_error
          | :transport_error
          | :too_large
          | :blocked
          | :invalid
          | :other
          | Parser.error()

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Ranges.enabled?() do
      config = Ranges.config()

      case Enum.reject(Engines.range_engines(), &(refresh(&1, config) == :ok)) do
        [] -> :ok
        failed -> {:error, {:crawler_ranges_failed, failed}}
      end
    else
      :ok
    end
  end

  @doc """
  Fetches, checks and installs `engine`'s list, and sends it to the other
  nodes. Answers the result telemetry reports.
  """
  @spec refresh(atom(), keyword()) :: result()
  def refresh(engine, config \\ Ranges.config()) do
    result =
      with {:ok, body} <- fetch(Engines.range_source(engine), config),
           {:ok, cidrs} <- parse(body, config) do
        Ranges.put(engine, cidrs)
        Ranges.broadcast(engine)
        :ok
      end

    report(engine, result)
    result
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

    if result != :ok do
      Logger.warning(
        "Crawler verification: could not refresh #{engine}'s published crawler IP " <>
          "ranges (#{result}); the list held before is kept until it goes stale"
      )
    end
  end
end
