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

  @csv_header ~w(kind at action who publish changed reference note
                 cdn_purge cdn_enqueued_at cdn_settled_at endpoints as_of chain)

  # The propagation columns, empty on every row that is not a transition.
  @no_propagation [nil, nil, nil, nil, nil, nil]

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
      # One row per publish or withdrawal with its propagation record (#1928):
      # the same columns as the dashboard's "What readers saw" table.
      transitions: Enum.map(trail.transitions, &transition_payload/1),
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
        end),
      # Retraction webhooks that exhausted their retries (#1926).
      lost_retractions:
        Enum.map(trail.lost_retractions, fn lost ->
          Map.take(lost, [
            :event,
            :endpoint_url,
            :attempts,
            :last_error,
            :failed_at,
            :recovered_at
          ])
        end)
    }
  end

  defp transition_payload(transition) do
    %{
      at: transition.at,
      action: transition.action,
      kind: transition.kind,
      scheduled?: transition.scheduled?,
      approver: transition.approver,
      as_of_url: transition.as_of_url,
      chain: chain_status(transition.chain),
      propagation: transition.propagation,
      propagation_missing: transition.propagation_missing
    }
  end

  # The flat CSV twin: one row per timeline event (kind `version`), consent
  # (kind `consent`) or lost retraction (kind `retraction_lost`, #1926: the
  # endpoint in `reference`, the error and any later delivery in `note`),
  # newest events first, consents and lost retractions after — review-ready in
  # any spreadsheet. Structured diff values stay in the JSON export; CSV
  # carries the changed field names.
  #
  # Transitions (#1928) come first, kind `transition`: the approver in `who`,
  # the dispatched event in `reference`, when the record settled in `note`, and
  # the propagation in the trailing columns, which every other kind leaves
  # empty. Appended, so a sheet reading the first eight columns by position
  # still lines up.
  defp csv(trail) do
    rows =
      Enum.map(trail.transitions, &transition_row/1) ++
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
          ] ++ @no_propagation
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
          ] ++ @no_propagation
        end) ++
        Enum.map(trail.lost_retractions, fn lost ->
          [
            "retraction_lost",
            iso(lost.failed_at),
            lost.event,
            nil,
            nil,
            nil,
            lost.endpoint_url,
            retraction_note(lost)
          ] ++ @no_propagation
        end)

    Enum.map_join([@csv_header | rows], &CSV.line/1)
  end

  defp transition_row(transition) do
    propagation = transition.propagation

    [
      "transition",
      DateTime.to_iso8601(transition.at),
      to_string(transition.action),
      transition.approver,
      to_string(transition.kind == :publish),
      nil,
      propagation && propagation.event,
      propagation_note(transition)
    ] ++
      if propagation do
        [
          to_string(propagation.cdn.status),
          iso(propagation.cdn.enqueued_at),
          iso(propagation.cdn.settled_at),
          endpoints_cell(propagation),
          transition.as_of_url,
          chain_status(transition.chain)
        ]
      else
        [nil, nil, nil, nil, transition.as_of_url, chain_status(transition.chain)]
      end
  end

  defp propagation_note(%{propagation: %{completed_at: %DateTime{} = at}}),
    do: "settled at #{DateTime.to_iso8601(at)}"

  defp propagation_note(%{propagation: %{}}), do: "not yet settled"
  defp propagation_note(%{propagation_missing: :pruned}), do: "propagation record pruned"
  defp propagation_note(%{propagation_missing: :not_live}), do: "nothing was live to take down"
  defp propagation_note(%{propagation_missing: :not_measured}), do: "restores are not measured"

  defp propagation_note(_transition),
    do: "no propagation record (made before 1.4, or not recorded)"

  # One entry per endpoint still in the ledger, `; `-separated, led by what the
  # record says of the ones whose delivery rows were pruned (#1928).
  defp endpoints_cell(propagation) do
    pruned =
      if propagation.endpoints_pruned > 0 do
        [
          "#{propagation.endpoints_pruned} endpoint(s) pruned from the ledger" <>
            pruned_outcome(propagation)
        ]
      else
        []
      end

    Enum.join(pruned ++ Enum.map(propagation.endpoints, &endpoint_cell/1), "; ")
  end

  defp pruned_outcome(%{all_delivered_at: %DateTime{} = at}),
    do: ", all delivered by #{iso(at)}"

  defp pruned_outcome(%{endpoints_failed: failed}) when is_integer(failed) and failed > 0,
    do: ", #{failed} given up on"

  defp pruned_outcome(_propagation), do: ""

  # `<url> delivered <at>`, `<url> failed <at> (<error>)[ recovered <at>]` or
  # `<url> pending`.
  defp endpoint_cell(%{status: :succeeded} = endpoint),
    do: "#{endpoint.url} delivered #{iso(endpoint.delivered_at)}"

  defp endpoint_cell(%{status: :failed} = endpoint) do
    "#{endpoint.url} failed #{iso(endpoint.failed_at) || "at an unrecorded time"}" <>
      if(endpoint.error, do: " (#{endpoint.error})", else: "") <>
      if(endpoint.recovered_at, do: " recovered #{iso(endpoint.recovered_at)}", else: "")
  end

  defp endpoint_cell(endpoint), do: "#{endpoint.url} #{endpoint.status}"

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp retraction_note(%{recovered_at: nil} = lost), do: lost.last_error

  defp retraction_note(lost),
    do: "#{lost.last_error}; delivered later at #{DateTime.to_iso8601(lost.recovered_at)}"

  defp chain_status({:tampered, reason}), do: "tampered: #{reason}"
  defp chain_status(status), do: to_string(status)

  # Every piece of content past (or approaching) its review cadence, org-wide.
  #
  # Not HTML: the body is a text/csv attachment, so browsers never render it as
  # a document.
  # sobelow_skip ["XSS.SendResp"]
  def export_health_csv(conn, _params) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(conn) == :admin do
      rows =
        HealthSummary.csv_rows(
          KilnCMSWeb.Tenant.current_org_id(conn),
          conn.assigns[:current_user]
        )

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
