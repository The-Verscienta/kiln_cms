defmodule KilnCMSWeb.FormEntriesExportController do
  @moduledoc """
  Downloadable CSV of a form's submissions (#477) —
  `GET /editor/forms/:id/entries/export.csv`, optionally `?status=new|reviewed|spam`.

  Admin-gated, not editor: submissions are visitor-provided data (frequently
  PII), and `KilnCMS.CMS.FormSubmission`'s own policy is admin-only —
  `KilnCMSWeb.AnalyticsExportController` gates at editor because
  `AnalyticsLive` itself is editor-visible; this mirrors
  `KilnCMSWeb.GovernanceController` instead, whose dashboard is admin-only.

  Columns are the form's own field set, in its configured order, plus
  `status`/`spam_score`/`submitted_at` — not a union of whatever keys happen
  to appear in the stored data, so a field an editor later removed still
  produces a stable column rather than reshaping the export underneath a
  script that expects yesterday's columns.

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

    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{form.slug}-entries.csv")
      )
      |> send_chunked(200)

    header = CSV.line(field_names ++ ["status", "spam_score", "submitted_at"])

    rows =
      Enum.map(submissions, fn submission ->
        values = Enum.map(field_names, &Map.get(submission.data, &1))

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
