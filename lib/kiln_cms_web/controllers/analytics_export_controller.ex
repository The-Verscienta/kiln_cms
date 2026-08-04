defmodule KilnCMSWeb.AnalyticsExportController do
  @moduledoc """
  Downloadable analytics export (#618, phase 1 of `docs/advanced-analytics-plan.md`) —
  `GET /editor/analytics/export.json` and `…/export.csv`.

  Makes the numbers already on `KilnCMSWeb.AnalyticsLive` portable: daily view
  buckets for a requested `from`/`to` window, with titles resolved the same
  way the dashboard resolves them (`KilnCMS.Analytics.Titles`). Gated at
  **editor**, not admin — `AnalyticsLive` itself is editor-visible
  (`:live_editor_required`), so admin-gating the export (as
  `KilnCMSWeb.GovernanceController` does for its own admin-only dashboard)
  would ship editors a download button that 403s.

  `search_queries` are out of scope for this export by design — see the
  design doc's [Export](../../../docs/advanced-analytics-plan.md#3-export)
  section: it is the one analytics table holding free text that can
  incidentally carry PII.

  Streams via `KilnCMS.Analytics.Export.stream_rows/4` and, when referrer
  attribution is enabled, `stream_referrer_rows/4` (`Ash.stream!` +
  `send_chunked/2`) rather than materializing the window: both `:in_range`
  reads are keyset-paginated for exactly this, and the requested span is
  capped at the bucket retention window so a request can't ask for an
  unbounded scan.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Analytics.Export
  alias KilnCMSWeb.CSV

  def export(conn, params), do: with_range(conn, params, &stream_json/2)
  def export_csv(conn, params), do: with_range(conn, params, &stream_csv/2)

  defp with_range(conn, params, fun) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(conn) in [:editor, :admin] do
      case parse_range(params) do
        {:ok, from, to} -> fun.(conn, {from, to})
        {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: reason})
      end
    else
      conn |> put_status(:forbidden) |> json(%{error: "editor_required"})
    end
  end

  # Not HTML: the body is a text/csv attachment (content type + disposition
  # set below), so browsers never render it as a document.
  # sobelow_skip ["XSS.SendResp"]
  defp stream_csv(conn, {from, to}) do
    org = KilnCMSWeb.Tenant.current_org(conn)
    actor = conn.assigns[:current_user]

    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="analytics-#{from}-#{to}.csv")
      )
      |> send_chunked(200)

    body_stream =
      [
        Export.stream_rows(from, to, org, actor),
        Export.stream_referrer_rows(from, to, org, actor)
      ]
      |> Stream.concat()
      |> Stream.map(fn {rows, titles} ->
        Enum.map_join(rows, &CSV.line(Export.csv_row(&1, titles, org)))
      end)

    [CSV.line(Export.csv_header())]
    |> Stream.concat(body_stream)
    |> Enum.reduce_while(conn, &write_chunk/2)
  end

  defp stream_json(conn, {from, to}) do
    org = KilnCMSWeb.Tenant.current_org(conn)
    actor = conn.assigns[:current_user]

    conn =
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="analytics-#{from}-#{to}.json")
      )
      |> send_chunked(200)

    body_stream =
      [
        Export.stream_rows(from, to, org, actor),
        Export.stream_referrer_rows(from, to, org, actor)
      ]
      |> Stream.concat()
      |> Stream.transform(false, fn {rows, titles}, sent_any? ->
        prefix = if sent_any?, do: ",", else: ""
        json = Enum.map_join(rows, ",", &Jason.encode!(Export.json_row(&1, titles, org)))
        {[prefix <> json], true}
      end)

    ["["]
    |> Stream.concat(body_stream)
    |> Stream.concat(["]"])
    |> Enum.reduce_while(conn, &write_chunk/2)
  end

  # A client disconnecting mid-download makes `chunk/2` return `{:error,
  # :closed}` — halt rather than crash on the next chunk (or the closing "]"
  # of a JSON export).
  defp write_chunk(body, conn) do
    case chunk(conn, body) do
      {:ok, conn} -> {:cont, conn}
      {:error, :closed} -> {:halt, conn}
    end
  end

  # The requested span, defaulting to the dashboard's own 30-day default and
  # capped at the bucket retention window so a caller can't request an
  # unbounded scan.
  defp parse_range(params) do
    today = Date.utc_today()

    with {:ok, to} <- parse_date(params["to"], today),
         {:ok, from} <- parse_date(params["from"], Date.add(to, -29)),
         :ok <- Export.validate_range(from, to) do
      {:ok, from, to}
    else
      {:error, reason} when is_atom(reason) -> {:error, to_string(reason)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_date(nil, default), do: {:ok, default}

  defp parse_date(raw, _default) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "invalid_date"}
    end
  end

  defp parse_date(_raw, _default), do: {:error, "invalid_date"}
end
