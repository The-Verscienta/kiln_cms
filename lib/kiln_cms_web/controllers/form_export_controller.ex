defmodule KilnCMSWeb.FormExportController do
  @moduledoc """
  CSV download of one form's submissions —
  `GET /editor/forms/:id/export.csv` (phase 6).

  One row per submission (newest first): timestamp, locale, then one column
  per value-producing field in the form's display order, plus columns for any
  data keys no current field claims (renamed/deleted fields — old entries keep
  their answers). Admin-only, gated against the `:browser`-loaded user like the
  governance exports. Streamed (chunked response + keyset-paginated read) so a
  form with a large submission history never materializes in memory.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS
  alias KilnCMS.CMS.{FormField, FormSubmission}
  alias KilnCMSWeb.CSV

  @batch 500

  # Not HTML: the body is a text/csv attachment (content type + disposition
  # set below), so browsers never render it as a document.
  # sobelow_skip ["XSS.SendResp"]
  def export_csv(conn, %{"id" => id}) do
    org = KilnCMSWeb.Tenant.current_org_id(conn)

    with :admin <- KilnCMSWeb.LiveUserAuth.effective_tier(conn),
         {:ok, form} <- CMS.get_form(id, authorize?: false, tenant: org) do
      fields = CMS.form_fields_for!(form.id, authorize?: false, tenant: org)
      columns = columns(form, fields, org)

      conn =
        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="form-#{form.slug}-submissions.csv")
        )
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, CSV.line(["submitted_at", "locale" | columns]))

      form.id
      |> stream(org)
      |> Enum.reduce_while(conn, &write_row(&1, &2, columns))
    else
      {:error, _error} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      _tier -> conn |> put_status(:forbidden) |> json(%{error: "admin_required"})
    end
  end

  # Field columns (in form order) plus any orphaned data keys from renamed or
  # deleted fields. The orphan scan streams the submissions, accumulating only
  # the (small) set of key strings — never the submissions themselves.
  defp columns(form, fields, org) do
    field_names =
      fields
      |> Enum.reject(&(&1.field_type in FormField.display_types()))
      |> Enum.map(& &1.name)

    known = MapSet.new(field_names)

    extras =
      form.id
      |> stream(org)
      |> Enum.reduce(MapSet.new(), fn submission, acc ->
        submission.data |> Map.keys() |> Enum.reduce(acc, &MapSet.put(&2, &1))
      end)
      |> MapSet.reject(&MapSet.member?(known, &1))
      |> Enum.sort()

    field_names ++ extras
  end

  defp write_row(submission, conn, columns) do
    case chunk(conn, CSV.line(row(submission, columns))) do
      {:ok, conn} -> {:cont, conn}
      # Client hung up mid-download — stop streaming.
      {:error, _reason} -> {:halt, conn}
    end
  end

  defp stream(form_id, org) do
    FormSubmission
    |> Ash.Query.for_read(:all_for_form, %{form_id: form_id}, authorize?: false, tenant: org)
    |> Ash.stream!(batch_size: @batch)
  end

  defp row(submission, columns) do
    [DateTime.to_iso8601(submission.inserted_at), submission.locale] ++
      Enum.map(columns, &display(Map.get(submission.data, &1)))
  end

  defp display(value) when is_list(value), do: Enum.join(value, "; ")
  defp display(value), do: value
end
