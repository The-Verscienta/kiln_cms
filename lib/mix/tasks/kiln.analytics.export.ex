defmodule Mix.Tasks.Kiln.Analytics.Export do
  @shortdoc "Export daily view analytics (#618)"

  @moduledoc """
  Streams the analytics export outside the browser download — for ops,
  backups, or piping into another tool:

      mix kiln.analytics.export --format=csv --from=2026-01-01 --to=2026-01-31
      mix kiln.analytics.export --format=json --org=<uuid> --out=export.json

  Writes to stdout by default; `--out <path>` writes to a file instead. When
  writing to stdout, the "done" summary goes to **stderr** so a piped export
  (`mix kiln.analytics.export > out.csv`) stays parseable — nothing but the
  export itself ever reaches stdout.

  `--org <uuid>` targets a specific site (defaults to the sole org).
  `--from`/`--to` default to the last 30 days, mirroring
  `KilnCMSWeb.AnalyticsExportController`, and are capped at the bucket
  retention window (`KilnCMS.Analytics.Export.max_days/0`).

  Passes an explicit actor — never `authorize?: false` — so the export goes
  through the same read policies (editor/admin only) as the browser download.
  Run from an operator's own shell, this task speaks for "an admin of this
  deployment"; it does not look up or impersonate a stored user.
  """

  use Mix.Task

  alias KilnCMS.Analytics.Export
  alias KilnCMSWeb.CSV

  @requirements ["app.start"]

  @switches [format: :string, from: :string, to: :string, org: :string, out: :string]

  # Satisfies `KilnCMS.Accounts.Scoping.effective_tier/2`'s admin short-circuit
  # (`effective_tier(%{role: :admin}, _subject) -> :admin`) with no DB lookup
  # and no `authorize?: false` — this in-memory actor speaks for the operator
  # running the task, not for any particular stored user.
  @actor %{role: :admin}

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: @switches)

    org_id = opts[:org] || KilnCMS.Accounts.default_org_id()
    format = normalize_format(opts[:format])
    {from, to} = range(opts)
    device = open_device(opts[:out])

    case format do
      :csv -> write_csv(device, from, to, org_id)
      :json -> write_json(device, from, to, org_id)
    end

    close_device(device)

    # Stdout carries only the export itself (so piping/redirecting it stays
    # parseable) — the summary goes to stderr, always, regardless of --out.
    IO.puts(
      :stderr,
      "Exported #{format} for org #{org_id}, #{from}..#{to}#{destination(opts[:out])}."
    )
  end

  defp normalize_format(nil), do: :csv

  defp normalize_format(raw) do
    case String.downcase(raw) do
      "csv" -> :csv
      "json" -> :json
      other -> Mix.raise("unknown --format #{inspect(other)} (expected csv or json)")
    end
  end

  defp range(opts) do
    today = Date.utc_today()
    to = parse_date!(opts[:to], today)
    from = parse_date!(opts[:from], Date.add(to, -29))

    case Export.validate_range(from, to) do
      :ok ->
        {from, to}

      {:error, :from_after_to} ->
        Mix.raise("--from must not be after --to")

      {:error, :range_too_large} ->
        Mix.raise(
          "--from/--to span more than #{Export.max_days()} days " <>
            "(the bucket retention window) — narrow the range"
        )
    end
  end

  defp parse_date!(nil, default), do: default

  defp parse_date!(raw, _default) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> date
      {:error, _} -> Mix.raise("invalid date #{inspect(raw)} (expected YYYY-MM-DD)")
    end
  end

  defp open_device(nil), do: :stdio
  defp open_device(path), do: File.open!(path, [:write, :utf8])

  defp close_device(:stdio), do: :ok
  defp close_device(device), do: File.close(device)

  defp destination(nil), do: " to stdout"
  defp destination(path), do: " to #{path}"

  defp rows(from, to, org_id) do
    Stream.concat([
      Export.stream_rows(from, to, org_id, @actor),
      Export.stream_referrer_rows(from, to, org_id, @actor),
      Export.stream_funnel_rows(from, to, org_id, @actor)
    ])
  end

  defp write_csv(device, from, to, org_id) do
    IO.write(device, CSV.line(Export.csv_header()))

    from
    |> rows(to, org_id)
    |> Enum.each(fn {batch, titles} ->
      IO.write(device, Enum.map_join(batch, &CSV.line(Export.csv_row(&1, titles, org_id))))
    end)
  end

  defp write_json(device, from, to, org_id) do
    IO.write(device, "[")

    _ =
      from
      |> rows(to, org_id)
      |> Enum.reduce(false, fn {batch, titles}, sent_any? ->
        prefix = if sent_any?, do: ",", else: ""
        json = Enum.map_join(batch, ",", &Jason.encode!(Export.json_row(&1, titles, org_id)))
        IO.write(device, prefix <> json)
        true
      end)

    IO.write(device, "]\n")
  end
end
