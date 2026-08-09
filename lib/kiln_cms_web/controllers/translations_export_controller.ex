defmodule KilnCMSWeb.TranslationsExportController do
  @moduledoc """
  XLIFF 2.0 download for the translation-vendor seam (#502) —
  `GET /editor/translations/export.xlf`.

  A controller route rather than a LiveView event because the result is a file:
  `KilnCMSWeb.TranslationsLive` builds the link and the browser fetches it.

  Editor-gated, like `KilnCMSWeb.AnalyticsExportController` and for the same
  reason — the coverage dashboard this downloads from is itself editor-visible,
  so admin-gating the export would ship editors a button that 403s. The export
  itself reads under the signed-in actor and the current site, so a file
  contains exactly what that editor could have opened one record at a time.

  ## Parameters

    * `target` — the target locale (required; must be a configured locale)
    * `record` — repeated `"<type>:<uuid>"`, the source records to export

  A batch is capped at `KilnCMS.CMS.Xliff.max_batch/0` records — the facade owns
  what an export is, so the cap lives there and both this route and the
  dashboard's selection read it rather than each carrying their own number.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Xliff
  alias KilnCMSWeb.Params

  def export(conn, params) do
    with :ok <- require_editor(conn),
         {:ok, target} <- fetch_target(params),
         {:ok, entries} <- fetch_records(conn, params),
         {:ok, result} <- Xliff.export_many(entries, target, scope(conn)) do
      send_xliff(conn, result, entries)
    else
      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "editor_required"})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: message(reason)})
    end
  end

  # Not HTML: an XLIFF attachment with an explicit content type and
  # disposition, so no browser renders it as a document.
  # sobelow_skip ["XSS.SendResp"]
  defp send_xliff(conn, result, entries) do
    slug =
      case entries do
        [{_kind, record}] -> record.slug
        _batch -> nil
      end

    filename = Xliff.filename(result.source_locale, result.target_locale, slug)

    conn
    |> put_resp_content_type("application/xliff+xml")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, result.xliff)
  end

  defp require_editor(conn) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(conn) in [:editor, :admin],
      do: :ok,
      else: {:error, :forbidden}
  end

  defp fetch_target(params) do
    case Params.string(params, "target", "") do
      "" -> {:error, :missing_locale}
      target -> {:ok, target}
    end
  end

  # `?record=a&record=b` and `?record[]=a` both arrive as a list; a single
  # `?record=a` arrives as a string. A map (`?record[x]=1`) is the bookmarkable
  # shape #764 is about — it is neither, and refusing beats crashing.
  defp fetch_records(conn, params) do
    case Map.get(params, "record") do
      value when is_binary(value) -> load(conn, [value])
      values when is_list(values) -> load(conn, Enum.filter(values, &is_binary/1))
      _absent_or_map -> {:error, :no_records}
    end
  end

  defp load(_conn, []), do: {:error, :no_records}

  defp load(conn, records) do
    scope = scope(conn)

    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case load_one(record, scope) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_one(record, scope) do
    with [kind, id] <- String.split(record, ":", parts: 2),
         {:ok, found} <- fetch_record(kind, id, scope) do
      {:ok, {kind, found}}
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, {:malformed_record, record}}
    end
  end

  # The rescue is around the dispatcher lookup only. Wrapping the whole load
  # turned a `Forbidden`, a malformed uuid and a pool timeout all into "no
  # records selected" — an editor missing read on one of fifty ticked rows was
  # told the selection was empty, and a genuine 500 never reached Sentry.
  defp fetch_record(kind, id, scope) do
    case ContentTypes.get_record(kind, id, scope) do
      {:ok, found} -> {:ok, found}
      {:error, _reason} -> {:error, {:record_not_found, "#{kind}:#{id}"}}
    end
  rescue
    # An unknown content type raises out of the dispatcher rather than
    # returning — a hand-edited query string should be a 400, not a 500.
    _error -> {:error, {:unknown_type, kind}}
  end

  defp scope(conn),
    do: [actor: conn.assigns[:current_user], tenant: KilnCMSWeb.Tenant.current_org(conn)]

  defp message(:missing_locale), do: "target locale required"
  defp message({:unknown_locale, locale}), do: "unknown locale: #{locale}"
  defp message(:no_records), do: "no records selected"
  defp message({:record_not_found, record}), do: "record not found: #{record}"
  defp message({:malformed_record, record}), do: "malformed record: #{record}"
  defp message({:unknown_type, kind}), do: "unknown content type: #{kind}"

  defp message({:too_many_records, given, max}),
    do: "too many records: #{given} (max #{max})"

  defp message({:same_locale, locale}),
    do: "source and target locale are both #{locale}"

  defp message({:mixed_source_locales, locales}),
    do: "records span several source locales: #{Enum.join(locales, ", ")}"

  defp message(other), do: inspect(other)
end
