defmodule KilnCMSWeb.FormExportController do
  @moduledoc """
  CSV download of one form's submissions —
  `GET /editor/forms/:id/export.csv` (phase 6).

  One row per submission (newest first): timestamp, locale, then one column
  per value-producing field in the form's display order, plus columns for
  any data keys no current field claims (renamed/deleted fields — old
  entries keep their answers). Admin-only, gated against the
  `:browser`-loaded user like the governance exports.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FormField

  # Not HTML: the body is a text/csv attachment (content type + disposition
  # set below), so browsers never render it as a document.
  # sobelow_skip ["XSS.SendResp"]
  def export_csv(conn, %{"id" => id}) do
    org = KilnCMSWeb.Tenant.current_org_id(conn)

    with :admin <- KilnCMSWeb.LiveUserAuth.effective_tier(conn),
         {:ok, form} <- CMS.get_form(id, authorize?: false, tenant: org) do
      submissions = CMS.all_form_submissions!(form.id, authorize?: false, tenant: org)
      fields = CMS.form_fields_for!(form.id, authorize?: false, tenant: org)

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="form-#{form.slug}-submissions.csv")
      )
      |> send_resp(200, csv(fields, submissions))
    else
      {:error, _error} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
      _tier -> conn |> put_status(:forbidden) |> json(%{error: "admin_required"})
    end
  end

  defp csv(fields, submissions) do
    field_names =
      fields
      |> Enum.reject(&(&1.field_type in FormField.display_types()))
      |> Enum.map(& &1.name)

    # Data keys no current field claims (renamed/deleted fields) still export.
    extras =
      submissions
      |> Enum.flat_map(&Map.keys(&1.data))
      |> Enum.uniq()
      |> Kernel.--(field_names)
      |> Enum.sort()

    columns = field_names ++ extras

    rows =
      Enum.map(submissions, fn submission ->
        [DateTime.to_iso8601(submission.inserted_at), submission.locale] ++
          Enum.map(columns, &display(Map.get(submission.data, &1)))
      end)

    Enum.map_join([["submitted_at", "locale" | columns] | rows], &csv_line/1)
  end

  defp display(value) when is_list(value), do: Enum.join(value, "; ")
  defp display(value), do: value

  defp csv_line(fields), do: Enum.map_join(fields, ",", &csv_field/1) <> "\r\n"

  # RFC 4180: quote a field when it holds a comma, quote, or newline; quotes
  # double. Prefix any formula-leading character so a spreadsheet app never
  # executes a cell that came from visitor-entered content (CSV injection).
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
end
