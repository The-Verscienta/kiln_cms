defmodule Mix.Tasks.Kiln.Propagation do
  @shortdoc "Publish and withdrawal propagation p50/p95 (#1927)"

  @moduledoc """
  How long publishes and withdrawals took to reach every webhook endpoint,
  from the propagation records (`KilnCMS.Propagation`):

      mix kiln.propagation                    # the last 7 days, both kinds
      mix kiln.propagation --days 1
      mix kiln.propagation --kind withdraw    # unpublish-to-last-endpoint only
      mix kiln.propagation --org-id UUID      # a site other than the default

  One line per kind:

      withdraw  n=42  p50=0.38s  p95=1.92s  max=4.10s  lost=0  no-endpoints=3  open=1

  `n` and the percentiles cover transitions whose every endpoint answered 2xx,
  measured from the transition to the last endpoint's 2xx. `lost` counts
  transitions where an endpoint was given up on (for a withdrawal, one that is
  on the governance trail as "Retraction not delivered"), `no-endpoints` the
  ones sent to none, and `open` the ones still waiting on a delivery or the
  CDN purge. `docs/benchmarks.md` describes how the published number was
  taken.
  """
  use Mix.Task

  @requirements ["app.start"]

  @switches [org_id: :string, days: :integer, kind: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _positional} = OptionParser.parse!(args, strict: @switches)
    org_id = opts[:org_id] || KilnCMS.Accounts.default_org_id()
    days = Keyword.get(opts, :days, 7)

    if days < 1, do: Mix.raise("--days must be at least 1")

    since = DateTime.add(DateTime.utc_now(), -days, :day)

    Mix.shell().info("Propagation for org #{org_id}, last #{days} day(s):")

    opts
    |> kinds()
    |> Enum.each(fn kind ->
      org_id
      |> KilnCMS.Propagation.percentiles(kind: kind, since: since)
      |> line()
      |> Mix.shell().info()
    end)
  end

  defp kinds(opts) do
    case opts[:kind] do
      nil -> [:withdraw, :publish]
      "withdraw" -> [:withdraw]
      "publish" -> [:publish]
      other -> Mix.raise("--kind must be withdraw or publish, got #{inspect(other)}")
    end
  end

  @doc false
  def line(stats) do
    Enum.join(
      [
        String.pad_trailing(to_string(stats.kind), 9),
        "n=#{stats.count}",
        "p50=#{seconds(stats.p50_ms)}",
        "p95=#{seconds(stats.p95_ms)}",
        "max=#{seconds(stats.max_ms)}",
        "lost=#{stats.lost}",
        "no-endpoints=#{stats.no_endpoints}",
        "open=#{stats.open}"
      ],
      "  "
    )
  end

  defp seconds(nil), do: "-"
  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 2) <> "s"
end
