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

  defp chain_status({:tampered, reason}), do: "tampered: #{reason}"
  defp chain_status(status), do: to_string(status)
end
