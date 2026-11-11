defmodule KilnCMSWeb.FormEntriesExportController do
  @moduledoc """
  Downloadable CSV of a form's submissions (#477) —
  `GET /editor/forms/:id/entries/export.csv`, optionally `?status=new|reviewed|spam`.

  Admin-gated, not editor: submissions are visitor-provided data (frequently
  PII), and `KilnCMS.CMS.FormSubmission`'s own policy is admin-only —
  `KilnCMSWeb.AnalyticsExportController` gates at editor because
  `AnalyticsLive` itself is editor-visible; this mirrors
  `KilnCMSWeb.GovernanceController` instead, whose dashboard is admin-only.

  Columns are the form's **current** field set, in its configured order, then
  one column per *orphaned* key, then `status`/`spam_score`/`submitted_at`. An
  orphaned key is one the exported submissions carry that no current field
  is named: what a field renamed or removed after those submissions arrived
  left behind (#2342). Each gets the header `"<key> (renamed or removed)"`,
  sorted by key, so its values are still in the export but never pass for a
  current field's, the same split as the Entries tab's "From a renamed or
  removed field" box. The suffix is a fixed English string, not gettext: it
  is a data header that spreadsheets and imports key on, like the raw
  machine names and `status`. A key equal to a current field's name (a
  reused name) is that field's column, as on the Entries tab.

  Orphaned columns come from the exported rows only (after `?status=`), so a
  form with no rename history, or a filter that leaves none of its old keys,
  exports exactly the current field set: the columns do not shift just
  because an admin added a field.

  Not streamed: unlike the analytics export, submission volume for one form
  has no comparable retention window to bound a request against, but a
  form's submissions are also nowhere near that scale — this is a materialize-
  and-write, same as the export button on `FormBuilderLive`'s own Entries tab.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS
  alias KilnCMSWeb.CSV

  # Not HTML: the body is a text/csv attachment (content type + disposition
  # set below), so browsers never render it as a document.
  # sobelow_skip ["XSS.SendResp"]
  def export_csv(conn, %{"id" => form_id} = params) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(conn) == :admin do
      actor = conn.assigns[:current_user]
      org = KilnCMSWeb.Tenant.current_org(conn)

      case CMS.get_form(form_id, actor: actor, tenant: org, load: [:fields]) do
        {:ok, form} -> stream_csv(conn, form, actor, org, parse_status(params["status"]))
        _ -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      end
    else
      conn |> put_status(:forbidden) |> json(%{error: "admin_required"})
    end
  end

  defp stream_csv(conn, form, actor, org, status) do
    submissions =
      CMS.export_form_submissions!(form.id, %{status: status}, actor: actor, tenant: org)

    field_names = Enum.map(form.fields, & &1.name)
    orphan_keys = orphan_keys(submissions, field_names)
    keys = field_names ++ orphan_keys

    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{form.slug}-entries.csv")
      )
      |> send_chunked(200)

    header =
      CSV.line(
        field_names ++
          Enum.map(orphan_keys, &(&1 <> " (renamed or removed)")) ++
          ["status", "spam_score", "submitted_at"]
      )

    rows =
      Enum.map(submissions, fn submission ->
        # A checkboxes value is a list: joined here, so `CSV.field/1` (and its
        # formula guard) sees one string. A phone number starting `+` or an
        # option starting `=` gets the guard's leading `'`.
        values =
          Enum.map(keys, fn name ->
            submission.data |> Map.get(name) |> KilnCMS.Forms.display_value()
          end)

        CSV.line(
          values ++
            [
              submission.status,
              submission.spam_score,
              DateTime.to_iso8601(submission.inserted_at)
            ]
        )
      end)

    [header | rows]
    |> Enum.reduce_while(conn, &write_chunk/2)
  end

  # Keys the exported submissions carry that no current field is named,
  # sorted. Bounded by the form's rename history: submission keys only ever
  # come from the form's fields at submit time (`KilnCMS.Forms` coerces against them).
  defp orphan_keys(submissions, field_names) do
    current = MapSet.new(field_names)

    submissions
    |> Enum.flat_map(&Map.keys(&1.data))
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(current, &1))
    |> Enum.sort()
  end

  defp write_chunk(body, conn) do
    case chunk(conn, body) do
      {:ok, conn} -> {:cont, conn}
      {:error, :closed} -> {:halt, conn}
    end
  end

  defp parse_status(status) when status in ~w(new reviewed spam),
    do: String.to_existing_atom(status)

  defp parse_status(_status), do: nil
end
