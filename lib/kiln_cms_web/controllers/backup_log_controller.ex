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
    3. The `:export` rate bucket of that admin, the one the backup file
       download and the security-log exports charge, else 429. A request
       refused above charges nothing.
    4. The run, read as the admin (`Backups.get_run/2`): an id that isn't a
       UUID, an unknown run and a refused read are the same 404.

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
         :ok <- charge(conn),
         {:ok, run} <- read(conn, id) do
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

  defp charge(conn) do
    case RateLimit.check(:export, "actor:" <> conn.assigns.current_user.id) do
      :allow -> :ok
      {:deny, retry_after_ms} -> {:deny, retry_after_ms}
    end
  end

  defp read(conn, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, run} <-
           Backups.get_run(id, actor: conn.assigns.current_user, authorize_with: :error) do
      {:ok, run}
    else
      _not_found -> {:error, :not_found}
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

  defp answer(_not_found),
    do: {404, "not_found", gettext("That backup isn't in the history.")}
end
