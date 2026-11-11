defmodule KilnCMSWeb.SecurityLogExportController do
  @moduledoc """
  The security log as a CSV download (#2241) -
  `GET /editor/security-log/export.csv`, taking the same `type`, `actor`,
  `from` and `to` params as `KilnCMSWeb.SecurityLogLive` (read by
  `KilnCMSWeb.SecurityLog`, so the file holds what the page shows).

  Admin-gated like the page: `LiveUserAuth.effective_tier/1` on this site, and
  the read itself runs as the signed-in admin in the site's tenant, so
  `KilnCMS.Security.Event`'s policy decides every row. Anyone else, an
  anonymous caller included, gets 403.

  Bounded like the content-list export (#2293): the `:export` rate bucket per
  actor, and `KilnCMSWeb.EditorLive.ListScope.export_cap/0` rows at most. A log
  with more matching rows answers 413 rather than a silently truncated file;
  narrow it with a date range. Rows are read in keyset pages and written as
  they arrive.

  The instance log (#2541) downloads the same way from
  `GET /editor/instance-security-log/export.csv` (`export_instance_csv/2`),
  gated on `LiveUserAuth.platform_admin?/1` instead, and read as the signed-in
  platform admin with no tenant, so `KilnCMS.Security.InstanceEvent`'s policy
  decides every row. A site admin who is not a platform admin gets 403.

  Cells go through `KilnCMSWeb.CSV`, which prefixes a leading `= + - @`, tab or
  carriage return with `'`: the actor label and the user agent are chosen by
  whoever made the request.
  """
  use KilnCMSWeb, :controller

  require Logger

  alias KilnCMS.Security
  alias KilnCMSWeb.CSV
  alias KilnCMSWeb.EditorLive.ListScope
  alias KilnCMSWeb.Plugs.RateLimit, as: RateLimitPlug
  alias KilnCMSWeb.RateLimit
  alias KilnCMSWeb.SecurityLog

  @page_size 500
  @header ~w(time type actor target_type target_id ip user_agent)

  # The body is a text/csv attachment, never a document.
  # sobelow_skip ["XSS.SendResp"]
  def export_csv(conn, params), do: export(conn, params, :site)

  @doc "The instance log's download (#2541): platform admins only."
  # sobelow_skip ["XSS.SendResp"]
  def export_instance_csv(conn, params), do: export(conn, params, :instance)

  # sobelow_skip ["XSS.SendResp"]
  defp export(conn, params, scope) do
    with :ok <- require_admin(conn, scope),
         :ok <- charge(conn),
         {:ok, args} <- arguments(conn, params, scope),
         :ok <- within_cap(conn, args, scope) do
      stream(conn, args, scope)
    else
      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "admin_required"})

      {:deny, retry_after_ms} ->
        RateLimitPlug.deny(conn, retry_after_ms)

      :no_such_actor ->
        # No such member: an empty file, the same as the page's empty list.
        stream(conn, :none, scope)

      :over_cap ->
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{
          error: "too_many_rows",
          message:
            gettext(
              "This export has more than %{max} rows. Narrow it with a date range and try again.",
              max: ListScope.export_cap()
            )
        })
    end
  end

  defp require_admin(conn, :site) do
    if KilnCMSWeb.LiveUserAuth.effective_tier(conn) == :admin,
      do: :ok,
      else: {:error, :forbidden}
  end

  # Not the site tier: the default site's admin is no platform admin.
  defp require_admin(conn, :instance) do
    if KilnCMSWeb.LiveUserAuth.platform_admin?(conn),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp charge(conn) do
    case RateLimit.check(:export, "actor:" <> conn.assigns.current_user.id) do
      :allow -> :ok
      {:deny, retry_after_ms} -> {:deny, retry_after_ms}
    end
  end

  defp arguments(conn, params, scope) do
    log = log(conn, scope)
    SecurityLog.arguments(SecurityLog.parse(params, log), conn.assigns.current_user, log)
  end

  # The `SecurityLog` scope: the request's site, or `:instance`.
  defp log(conn, :site), do: KilnCMSWeb.Tenant.current_org(conn)
  defp log(_conn, :instance), do: :instance

  defp opts(conn, :site),
    do: [actor: conn.assigns.current_user, tenant: KilnCMSWeb.Tenant.current_org(conn)]

  defp opts(conn, :instance), do: [actor: conn.assigns.current_user]

  defp resource(:site), do: Security.Event
  defp resource(:instance), do: Security.InstanceEvent

  # An exact count bounded at cap + 1: never the whole table.
  defp within_cap(conn, args, scope) do
    cap = ListScope.export_cap()

    count =
      resource(scope)
      |> Ash.Query.for_read(:list, args, opts(conn, scope))
      |> Ash.Query.limit(cap + 1)
      |> Ash.count!(opts(conn, scope))

    if count > cap, do: :over_cap, else: :ok
  end

  defp stream(conn, args, scope) do
    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{filename(scope)}-#{Date.utc_today()}.csv")
      )
      |> put_resp_header("cache-control", "no-store")
      |> send_chunked(200)

    {conn, rows} =
      case chunk(conn, CSV.bom() <> CSV.line(@header)) do
        {:ok, conn} when args != :none -> write_pages(conn, args, scope)
        {:ok, conn} -> {conn, 0}
        {:error, _closed} -> {conn, 0}
      end

    user_id = conn.assigns.current_user.id

    case scope do
      :site ->
        org_id = KilnCMS.Accounts.org_id(KilnCMSWeb.Tenant.current_org(conn))
        Logger.info("security log export user_id=#{user_id} org_id=#{org_id} rows=#{rows}")

      :instance ->
        Logger.info("instance security log export user_id=#{user_id} rows=#{rows}")
    end

    conn
  end

  defp filename(:site), do: "security-log"
  defp filename(:instance), do: "instance-security-log"

  defp write_pages(conn, args, scope) do
    opts = opts(conn, scope) ++ [page: [limit: @page_size, count: false], authorize_with: :error]

    first =
      case scope do
        :site -> Security.list_events!(args, opts)
        :instance -> Security.list_instance_events!(args, opts)
      end

    write_page(conn, first, 0)
  end

  defp write_page(conn, page, rows) do
    body = page.results |> Enum.map(&row/1) |> IO.iodata_to_binary()

    case chunk(conn, body) do
      {:ok, conn} ->
        rows = rows + length(page.results)

        if page.more? and rows < ListScope.export_cap() do
          write_page(conn, Ash.page!(page, :next), rows)
        else
          {conn, rows}
        end

      # The client went away mid-download; there is nobody to finish for.
      {:error, _closed} ->
        {conn, rows}
    end
  end

  defp row(event) do
    CSV.line([
      DateTime.to_iso8601(event.inserted_at),
      event.type,
      event.actor_label,
      event.target_type,
      event.target_id,
      event.ip,
      event.user_agent
    ])
  end
end
