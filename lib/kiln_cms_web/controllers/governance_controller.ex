defmodule KilnCMSWeb.GovernanceController do
  @moduledoc """
  Downloadable governance trail (#352) —
  `GET /editor/governance/:type/:id/export.json` and `…/export.csv`.

  Exports of a content item's audit trail (version timeline + linked
  consents), for compliance/legal records: JSON carries the full structure
  (diffs, chain verdict), CSV is the flat spreadsheet-friendly twin (one row
  per timeline event or consent). Admin-only, gated by the signed-in user
  loaded in the `:browser` pipeline.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Governance

  def export(conn, %{"type" => type, "id" => id}) do
    with_trail(conn, type, id, fn conn, trail ->
      conn
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="governance-#{type}-#{id}.json")
      )
      |> json(payload(trail))
    end)
  end

  # Not HTML: the body is a text/csv attachment (content type + disposition
  # set below), so browsers never render it as a document.
  # sobelow_skip ["XSS.SendResp"]
  def export_csv(conn, %{"type" => type, "id" => id}) do
    with_trail(conn, type, id, fn conn, trail ->
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="governance-#{type}-#{id}.csv")
      )
      |> send_resp(200, csv(trail))
    end)
  end

  defp with_trail(conn, type, id, fun) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(conn) == :admin do
      case Governance.trail(type, id, KilnCMSWeb.Tenant.current_org_id(conn)) do
        nil -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
        trail -> fun.(conn, trail)
      end
    else
      conn |> put_status(:forbidden) |> json(%{error: "admin_required"})
    end
  end

  # JSON-safe payload: the timeline's `{old, new}` diff tuples become
  # `%{old, new}` objects, the chain verdict a string; consent structs are
  # reduced to their public fields.
  defp payload(trail) do
    %{
      item: trail.item,
      generated_at: DateTime.utc_now(),
      chain: chain_status(trail.chain),
      unanchored_tail: trail.unanchored_tail,
      timeline:
        Enum.map(trail.timeline, fn event ->
          %{
            action: event.action,
            at: event.at,
            actor: event.actor,
            publish?: event.publish?,
            changed: Enum.map(event.diffs, &elem(&1, 0)),
            diffs:
              Map.new(event.diffs, fn {field, {old, new}} ->
                {field, %{old: old, new: new}}
              end)
          }
        end),
      consents:
        Enum.map(trail.consents, fn consent ->
          %{
            kind: consent.kind,
            grantor: consent.grantor,
            reference: consent.reference,
            note: consent.note,
            granted_at: consent.granted_at,
            recorded_by_id: consent.recorded_by_id
          }
        end)
    }
  end

  # The flat CSV twin: one row per timeline event (kind `version`) or consent
  # (kind `consent`), newest events first, consents after — review-ready in
  # any spreadsheet. Structured diff values stay in the JSON export; CSV
  # carries the changed field names.
  defp csv(trail) do
    rows =
      Enum.map(trail.timeline, fn event ->
        [
          "version",
          DateTime.to_iso8601(event.at),
          to_string(event.action),
          event.actor,
          to_string(event.publish?),
          Enum.map_join(event.diffs, "; ", &to_string(elem(&1, 0))),
          nil,
          nil
        ]
      end) ++
        Enum.map(trail.consents, fn consent ->
          [
            "consent",
            consent.granted_at && DateTime.to_iso8601(consent.granted_at),
            to_string(consent.kind),
            consent.grantor,
            nil,
            nil,
            consent.reference,
            consent.note
          ]
        end)

    Enum.map_join([~w(kind at action who publish changed reference note) | rows], &csv_line/1)
  end

  defp csv_line(fields), do: Enum.map_join(fields, ",", &csv_field/1) <> "\r\n"

  # RFC 4180: quote a field when it holds a comma, quote, or newline; quotes
  # double. Prefix any formula-leading character so a spreadsheet app never
  # executes a cell that came from user-entered content (CSV injection).
  defp csv_field(nil), do: ""

  defp csv_field(value) do
    value = to_string(value)
    value = if String.match?(value, ~r/\A[=+\-@\t\r]/), do: "'" <> value, else: value

    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp chain_status({:tampered, reason}), do: "tampered: #{reason}"
  defp chain_status(status), do: to_string(status)
end
