defmodule KilnCMSWeb.GovernanceController do
  @moduledoc """
  Downloadable governance trail (#352) —
  `GET /editor/governance/:type/:id/export.json` and `…/export.csv`.

  Exports of a content item's audit trail (version timeline + linked
  consents), for compliance/legal records: JSON carries the full structure
  (diffs, chain verdict), CSV is the flat spreadsheet-friendly twin (one row
  per timeline event or consent). Admin-only, gated by the signed-in user
  loaded in the `:browser` pipeline.

  Also `GET /editor/governance/health.csv` — the whole site's unhealthy content
  (docs/content-lifecycles.md), which is org-wide rather than per item and
  exists because the dashboard panel shows ten rows and an audit wants all of
  them.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.HealthSummary
  alias KilnCMS.Governance
  alias KilnCMSWeb.CSV

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
      # Sibling fact, not part of the verdict (#1058): whether this chain's
      # anchors could have hit the pre-#598 false-tamper bug. See
      # `KilnCMS.Governance.Chain.predates_fold_order?/1`.
      chain_predates_fold_order?: trail.predates_fold_order?,
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

    Enum.map_join([~w(kind at action who publish changed reference note) | rows], &CSV.line/1)
  end

  defp chain_status({:tampered, reason}), do: "tampered: #{reason}"
  defp chain_status(status), do: to_string(status)

  # Every piece of content past (or approaching) its review cadence, org-wide.
  #
  # Not HTML: the body is a text/csv attachment, so browsers never render it as
  # a document.
  # sobelow_skip ["XSS.SendResp"]
  def export_health_csv(conn, _params) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(conn) == :admin do
      rows = HealthSummary.csv_rows(KilnCMSWeb.Tenant.current_org_id(conn))
      header = ~w(type title health due_at id)

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="content-health.csv")
      )
      |> send_resp(200, Enum.map_join([header | rows], &CSV.line/1))
    else
      conn |> put_status(:forbidden) |> json(%{error: "admin_required"})
    end
  end
end
