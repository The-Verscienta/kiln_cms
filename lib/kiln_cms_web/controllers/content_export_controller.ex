defmodule KilnCMSWeb.ContentExportController do
  @moduledoc """
  The content list as a download (#2293) — `GET /editor/content/export.csv`
  and `…/export.json`.

  Takes the same params as `/editor` (`type`, `status`, `q`, `cf`, `sort`, …),
  checks them with the list's own `Filters.parse/2` against the types the
  actor can author (`ListScope`), and exports those rows. A selection is
  `ids=<uuid>,<uuid>` (at most 100): the filters are then ignored apart from
  `type`, so a selection that predates a filter change is not narrowed by it.
  Foreign or unreadable ids are simply absent, as in the list.

  Columns are the fixed `id,type,title,slug,status,locale,updated_at` plus the
  field columns the user saved for that type in the list (never the URL), up
  to the list's own cap. Private fields are left out unless `private=1`.

  Gated at **editor**, like the list, and every read runs as the actor in the
  site's tenant, so Ash policies decide each row. Other limits:

    * `:export` rate bucket, per actor (HEAD is neither charged nor streamed);
    * an exact bounded count first: over `ListScope.export_cap/0` rows the
      answer is 413 with a message, never a truncated file;
    * the same cap and a time limit again inside the stream
      (`ContentExport`), whose failure leaves the download visibly unfinished:
      the connection is dropped with the chunked body unterminated, so a CSV
      is cut off and a JSON array is never closed.

  With `type=all` the types are exported one after another, not merged into
  one order as the list does.

  Logged as metadata only (user, org, type, row count, column names, whether
  private fields were included) — never a value or the filter text.
  """
  use KilnCMSWeb, :controller

  require Logger

  alias KilnCMS.I18n
  alias KilnCMSWeb.ContentExport
  alias KilnCMSWeb.CSV
  alias KilnCMSWeb.EditorLive.Filters
  alias KilnCMSWeb.EditorLive.ListScope
  alias KilnCMSWeb.Plugs.RateLimit, as: RateLimitPlug
  alias KilnCMSWeb.RateLimit

  def export_csv(conn, params), do: run(conn, params, :csv)
  def export_json(conn, params), do: run(conn, params, :json)

  defp run(conn, params, format) do
    with :ok <- require_editor(conn),
         :ok <- not_head(conn, format),
         :ok <- charge(conn),
         {:ok, plan, type} <- plan(conn, params),
         :ok <- within_cap(plan) do
      stream(conn, plan, format, type, params["private"] == "1")
    else
      {:head, conn} -> conn
      {:error, status, code} -> refuse(conn, params, status, code)
      {:deny, retry_after_ms} -> RateLimitPlug.deny(conn, retry_after_ms)
    end
  end

  defp require_editor(conn) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(conn) in [:editor, :admin],
      do: :ok,
      else: {:error, :forbidden, "editor_required"}
  end

  # `Plug.Head` has turned a HEAD into a GET by now; the endpoint kept the fact.
  # Headers only: no charge to the budget, no reads, no stream.
  defp not_head(conn, format) do
    if conn.private[:kiln_head?] do
      {:head,
       conn
       |> put_download_headers(format, "content")
       |> send_resp(200, "")}
    else
      :ok
    end
  end

  defp charge(conn) do
    case RateLimit.check(:export, "actor:" <> conn.assigns.current_user.id) do
      :allow -> :ok
      {:deny, retry_after_ms} -> {:deny, retry_after_ms}
    end
  end

  defp plan(conn, params) do
    actor = conn.assigns.current_user
    org = KilnCMSWeb.Tenant.current_org(conn)
    types = ListScope.types(actor, org)
    ctx = ListScope.filter_ctx(types, I18n.locales(), actor, org)

    with :ok <- type_in_scope(params["type"], ctx.types),
         {:ok, ids} <- ids(params) do
      # A selection ignores every filter but the type it was made in.
      filters = Filters.parse(if(ids, do: Map.take(params, ["type"]), else: params), ctx)
      read_types = ListScope.filtered_types(types, filters["type"])
      column_type = ListScope.column_type(types, filters["type"])

      options =
        if column_type,
          do: ListScope.field_definitions(types, ListScope.type_value(column_type), actor, org),
          else: []

      columns = columns(actor, org, column_type, options, params["private"] == "1")

      plan = %{
        actor: actor,
        org: org,
        types: read_types,
        filters: filters,
        extra: if(ids, do: [filter: [id: [in: ids]]], else: []),
        columns: columns,
        options: options
      }

      {:ok, plan, filters["type"]}
    end
  end

  # The list falls back to "all" for a type it does not know; a download asked
  # for one the actor cannot author says no instead of exporting something else.
  defp type_in_scope(type, allowed) when is_binary(type) do
    if type in ["", "all" | allowed], do: :ok, else: {:error, :forbidden, "type_out_of_scope"}
  end

  defp type_in_scope(_type, _allowed), do: :ok

  defp ids(%{"ids" => raw}) when is_binary(raw) do
    parts = String.split(raw, ",", trim: true)
    uuids = Enum.map(parts, &Ecto.UUID.cast/1)

    cond do
      parts == [] or :error in uuids -> {:error, :bad_request, "invalid_ids"}
      length(parts) > ListScope.max_ids() -> {:error, :bad_request, "too_many_ids"}
      true -> {:ok, uuids |> Enum.map(fn {:ok, uuid} -> uuid end) |> Enum.uniq()}
    end
  end

  defp ids(%{"ids" => _other}), do: {:error, :bad_request, "invalid_ids"}
  defp ids(_params), do: {:ok, nil}

  # The user's saved columns for the type, re-read against what they may see.
  defp columns(_actor, _org, nil, _options, _private?), do: []

  defp columns(actor, org, column_type, options, private?) do
    readable = KilnCMS.CMS.ListFields.readable_fields(actor, org, options, private?)
    names = ListScope.column_names(actor, org, column_type, readable)
    KilnCMS.CMS.ListFields.resolve_columns(names, readable)
  end

  defp within_cap(plan) do
    %{types: types, filters: filters, actor: actor, org: org} = plan

    case ListScope.export_count(types, filters, actor, org, plan.options, plan.extra) do
      {:ok, _count} -> :ok
      :over_cap -> {:error, :request_entity_too_large, "too_many_rows"}
    end
  end

  # A refusal is JSON for a script. A person who clicked a link in the list
  # (the browser asks for HTML) goes back to the list with the reason as a
  # flash, instead of landing on a raw JSON body. A non-editor has no list to go
  # back to, so that refusal stays JSON.
  defp refuse(conn, params, status, code) do
    if code != "editor_required" and html?(conn) do
      conn
      |> put_flash(:error, message(code))
      |> redirect(to: back_to_list(params, code))
    else
      conn
      |> put_status(status)
      |> json(%{error: code, message: message(code)})
    end
  end

  defp html?(conn) do
    conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/html"))
  end

  # The list the person came from, minus whatever the refusal was about: a bad
  # selection drops `ids`, an unknown type drops `type`; an over-cap export keeps
  # the filters so they can be narrowed.
  defp back_to_list(params, code) do
    drop =
      case code do
        "type_out_of_scope" -> ["ids", "private", "type"]
        _other -> ["ids", "private"]
      end

    query = params |> Map.drop(drop) |> Map.filter(fn {_key, value} -> is_binary(value) end)

    if query == %{}, do: ~p"/editor", else: ~p"/editor?#{query}"
  end

  defp message("editor_required"), do: gettext("Exporting content needs an editor account.")

  defp message("type_out_of_scope"),
    do: gettext("You cannot export that content type.")

  defp message("invalid_ids"), do: gettext("The selection is not a list of content ids.")

  defp message("too_many_ids"),
    do: gettext("Select at most %{max} rows to export.", max: ListScope.max_ids())

  defp message("too_many_rows") do
    gettext("This export has more than %{max} rows. Narrow the list with a filter and try again.",
      max: ListScope.export_cap()
    )
  end

  # The body is a text/csv or application/json attachment, never a document
  # (and `put_secure_browser_headers` sets nosniff).
  # sobelow_skip ["XSS.SendResp"]
  defp stream(conn, plan, format, type, private?) do
    conn = conn |> put_download_headers(format, type) |> send_chunked(200)

    {conn, rows} =
      case chunk(conn, opening(format, plan)) do
        {:ok, conn} -> write_pages(conn, plan, format)
        {:error, _} -> {conn, 0}
      end

    metadata = [
      user_id: plan.actor.id,
      org_id: KilnCMS.Accounts.org_id(plan.org),
      type: type,
      format: format,
      rows: rows,
      columns: Enum.map(plan.columns, & &1.name),
      include_private: private?
    ]

    Logger.info("content export", metadata)

    :telemetry.execute(
      [:kiln_cms, :content_export, :stop],
      %{rows: rows},
      Map.new(metadata)
    )

    conn
  end

  defp opening(:csv, plan), do: CSV.bom() <> CSV.line(ContentExport.header(plan))
  defp opening(:json, _plan), do: "["

  defp write_pages(conn, plan, format) do
    {conn, rows, _first?} =
      plan
      |> ContentExport.stream()
      |> Enum.reduce_while({conn, 0, true}, fn
        {_descriptor, [], _labels}, acc ->
          {:cont, acc}

        {descriptor, records, labels}, {conn, rows, first?} ->
          body = page_body(plan, format, descriptor, records, labels, first?)

          case chunk(conn, body) do
            {:ok, conn} -> {:cont, {conn, rows + length(records), false}}
            # The client went away mid-download; there is nobody to finish for.
            {:error, _} -> {:halt, {conn, rows, first?}}
          end
      end)

    # Reached only when the whole stream was read: a failure raises out of the
    # reduce above, leaving the JSON array unclosed and the body unterminated.
    case format do
      :json -> {close_json(conn), rows}
      :csv -> {conn, rows}
    end
  end

  defp page_body(plan, :csv, descriptor, records, labels, _first?),
    do: plan |> ContentExport.csv_rows(descriptor, records, labels) |> IO.iodata_to_binary()

  defp page_body(plan, :json, descriptor, records, labels, first?) do
    json = plan |> ContentExport.json_rows(descriptor, records, labels) |> Enum.join(",")
    if first?, do: json, else: "," <> json
  end

  defp close_json(conn) do
    case chunk(conn, "]") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp put_download_headers(conn, format, type) do
    conn
    |> put_content_type(format)
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{filename(type, format)}")
    )
    |> put_resp_header("cache-control", "no-store")
  end

  # One literal per format, so the type is never a computed string.
  defp put_content_type(conn, :csv), do: put_resp_content_type(conn, "text/csv")
  defp put_content_type(conn, :json), do: put_resp_content_type(conn, "application/json")

  # Whitelisted characters only: a dynamic type's name is an editor's text.
  defp filename(type, format) do
    safe = type |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "") |> String.slice(0, 40)
    "content-#{if safe == "", do: "export", else: safe}-#{Date.utc_today()}.#{format}"
  end
end
