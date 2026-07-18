defmodule KilnCMSWeb.GovernanceController do
  @moduledoc """
  Downloadable governance trail (#352) — `GET /editor/governance/:type/:id/export.json`.

  A JSON export of a content item's audit trail (version timeline + linked
  consents), for compliance/legal records. Admin-only, gated by the signed-in
  user loaded in the `:browser` pipeline.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Governance

  def export(conn, %{"type" => type, "id" => id}) do
    case conn.assigns[:current_user] do
      %{role: :admin} ->
        case Governance.trail(type, id) do
          nil ->
            conn |> put_status(:not_found) |> json(%{error: "not_found"})

          trail ->
            conn
            |> put_resp_header(
              "content-disposition",
              ~s(attachment; filename="governance-#{type}-#{id}.json")
            )
            |> json(payload(trail))
        end

      _ ->
        conn |> put_status(:forbidden) |> json(%{error: "admin_required"})
    end
  end

  # JSON-safe payload: the timeline is already plain maps; consent structs are
  # reduced to their public fields.
  defp payload(trail) do
    %{
      item: trail.item,
      generated_at: DateTime.utc_now(),
      timeline: trail.timeline,
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
end
