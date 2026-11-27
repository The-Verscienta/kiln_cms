defmodule KilnCMSWeb.BackupLogController do
  @moduledoc """
  One backup run's log as a text file (part of #2230):
  `GET /editor/backups/runs/:id/log.txt`, what the Log tab
  (`KilnCMSWeb.BackupLogLive`) shows, every level, from
  `KilnCMS.Backups.LogText.render_text/2`: redacted again and sanitized.
  A running backup's log downloads too, as far as it has been written.

  ## In this order

    1. A platform admin, now (`LiveUserAuth.platform_admin?/1`), else 403.
    2. Not while the console shares an origin with several organizations'
       sites (`Backups.download_refusal/0`, which fails closed), else 403:
       a run's log names destinations, hosts, paths and timings across every
       organization's backups, so it follows the backup download's rule.
    3. A request the admin made here (Fetch Metadata, `fetch_ok/1`), else
       403 `cross_site_request`: a browser that says `Sec-Fetch-Site` must
       say `same-origin` or `none` (a typed URL or a bookmark), and one that
       says `Sec-Fetch-Dest` must say `document` (the Download link) or
       `empty` (a same-origin `fetch`). Otherwise an `<img>` on an
       organization's site under the same registrable domain, which the
       Lax session cookie still reaches, would spend the bucket below for
       the admin. A request without the headers (an older browser, curl)
       is let through: they are a browser's, and a client that omits them
       is spending its own bucket on purpose.
    4. The run, read as the admin (`Backups.get_run/2`): an id that isn't a
       UUID (cast before any read), an unknown run and a refused read are
       the same 404, and charge nothing. Every refusal above answers the
       same whether the id exists, so only an admin on the console learns
       that, and run ids are random UUIDs, so guessing them never paid.
    5. The `:export` rate bucket of that admin, the one the backup file
       download and the security-log exports charge, else 429. Only a run
       that is found is charged: the bucket rations an admin's downloads,
       not their typos.

  A GET with no token: it changes nothing, and the path carries only the
  run's id. A cross-site GET can only start a download in the admin's own
  browser, which the same-origin policy keeps the other site from reading.
  Each download is logged (`Logger.info`), as the instance security-log
  export is; it records no instance security event.

  Every refusal is `text/plain`: a message, then `error: <code>`.
  """
  use KilnCMSWeb, :controller

  require Logger

  alias KilnCMS.Backups
  alias KilnCMS.Backups.LogText
  alias KilnCMSWeb.LiveUserAuth
  alias KilnCMSWeb.Plugs.RateLimit, as: RateLimitPlug
  alias KilnCMSWeb.RateLimit

  @doc "The log download (`GET`)."
  def show(conn, %{"id" => id}) do
    with :ok <- require_admin(conn),
         :ok <- origin_ok(),
         :ok <- fetch_ok(conn),
         {:ok, id} <- cast_id(id),
         {:ok, run} <- read(conn, id),
         :ok <- charge(conn) do
      send_log(conn, run)
    else
      {:deny, retry_after_ms} -> RateLimitPlug.deny(conn, retry_after_ms)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp require_admin(conn) do
    if LiveUserAuth.platform_admin?(conn), do: :ok, else: {:error, :forbidden}
  end

  defp origin_ok do
    case Backups.download_refusal() do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  @fetch_sites ["same-origin", "none"]
  @fetch_dests ["document", "empty"]

  defp fetch_ok(conn) do
    if allowed?(conn, "sec-fetch-site", @fetch_sites) and
         allowed?(conn, "sec-fetch-dest", @fetch_dests),
       do: :ok,
       else: {:error, :cross_site_request}
  end

  # Absent is allowed; present, every value must be one of `allowed`.
  defp allowed?(conn, header, allowed),
    do: conn |> get_req_header(header) |> Enum.all?(&(String.downcase(&1) in allowed))

  defp charge(conn) do
    case RateLimit.check(:export, "actor:" <> conn.assigns.current_user.id) do
      :allow -> :ok
      {:deny, retry_after_ms} -> {:deny, retry_after_ms}
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp read(conn, id) do
    case Backups.get_run(id, actor: conn.assigns.current_user, authorize_with: :error) do
      {:ok, run} -> {:ok, run}
      {:error, _not_found} -> {:error, :not_found}
    end
  end

  # The body is the run's log as LogText renders it: redacted again and with
  # control characters replaced, served as an attachment and never sniffed.
  # sobelow_skip ["XSS.SendResp"]
  defp send_log(conn, run) do
    body = LogText.render_text(run)

    Logger.info(
      "backup log download user_id=#{conn.assigns.current_user.id} run_id=#{run.id} " <>
        "stamp=#{run.stamp} entries=#{length(run.log)}"
    )

    conn
    |> put_resp_content_type("text/plain", "utf-8")
    # The stamp is held to `\d{8}-\d{6}` by the Run resource, so it needs no
    # quoting.
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="kiln-backup-log-#{run.stamp}.txt")
    )
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-robots-tag", "noindex")
    |> send_resp(200, body)
  end

  # A plain-text refusal: the message, then the code a script can branch on.
  # sobelow_skip ["XSS.SendResp"]
  defp refuse(conn, reason) do
    {status, code, message} = answer(reason)

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(status, message <> "\n\nerror: " <> code <> "\n")
  end

  defp answer(:forbidden),
    do: {403, "admin_required", gettext("Only a platform admin can download backup logs.")}

  defp answer(:console_shares_origin),
    do:
      {403, "console_shares_origin",
       gettext(
         "Backup logs are off while the console shares its address with your organizations' sites. Set KILN_CONSOLE_HOST to read them."
       )}

  defp answer(:cross_site_request),
    do:
      {403, "cross_site_request",
       gettext("Download a backup's log from its Log tab in the console.")}

  defp answer(_not_found),
    do: {404, "not_found", gettext("That backup isn't in the history.")}
end
