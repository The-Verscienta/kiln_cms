defmodule KilnCMSWeb.BackupDownloadController do
  @moduledoc """
  One local file of a backup, as a download (part of #2225):
  `POST /editor/backups/download`, with the one-minute
  `KilnCMSWeb.BackupDownloadToken` the History page minted on click in the
  body (`token`) and the CSRF token beside it. The answer is the file as an
  `attachment`, streamed with `send_file`.

  A POST, not a GET with the token in its path, so the token is a body
  parameter that `:filter_parameters` keeps out of every log line (an older
  node's too, during a rolling deploy), and out of the browser's history and
  downloads list. A GET or HEAD here is 405 and touches nothing.

  ## In this order

    1. A platform admin, now (`LiveUserAuth.platform_admin?/1`): a user
       demoted, or whose grant expired, since the click is refused.
    2. The `:export` rate bucket of that admin, so guessing tokens costs too.
    3. The token: this application's, not expired, for this user and this
       browser session (the jti of the session's sign-in, #2490).
    4. This node's backup-directory id equals the one the click saw: a
       request that reached another server than the page's is told so (409),
       not a bare 404.
    5. `KilnCMS.Backups.download/4`, as the admin: every check of
       `KilnCMS.Backups.Run.Actions.Download` again (the name against the
       row, the origin refusal, the lock, the pin, `lstat`), then the
       `backup_downloaded` instance event. The path comes back only once the
       event is written.
    6. `send_file`.

  Every refusal is `text/plain`: a message, then `error: <code>`. Every
  refusal about the file itself is the same 404 (`not_found`), so nothing is
  said about which files exist.
  """
  use KilnCMSWeb, :controller

  require Logger

  alias KilnCMS.Accounts.Token
  alias KilnCMS.Backups
  alias KilnCMS.Security.Recorder
  alias KilnCMSWeb.BackupDownloadToken
  alias KilnCMSWeb.LiveUserAuth
  alias KilnCMSWeb.Plugs.RateLimit, as: RateLimitPlug
  alias KilnCMSWeb.RateLimit

  @doc "The download (`POST`)."
  def create(conn, params) do
    with :ok <- require_admin(conn),
         :ok <- charge(conn),
         {:ok, claims} <- BackupDownloadToken.verify(params["token"]),
         :ok <- same_session(conn, claims),
         :ok <- same_directory(claims),
         {:ok, download} <-
           Backups.download(
             claims.run_id,
             claims.file,
             conn.assigns.current_user,
             Recorder.context(conn)
           ) do
      send_backup_file(conn, download)
    else
      {:deny, retry_after_ms} -> RateLimitPlug.deny(conn, retry_after_ms)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @doc "A GET or HEAD of the download's path: 405, with nothing charged, read or recorded."
  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> refuse(:method_not_allowed)
  end

  defp require_admin(conn) do
    if LiveUserAuth.platform_admin?(conn), do: :ok, else: {:error, :forbidden}
  end

  defp charge(conn) do
    case RateLimit.check(:export, "actor:" <> conn.assigns.current_user.id) do
      :allow -> :ok
      {:deny, retry_after_ms} -> {:deny, retry_after_ms}
    end
  end

  # The token names this user and this browser's sign-in: another admin's, or
  # one minted in another session of the same account, is refused.
  defp same_session(conn, %{user_id: user_id, session_jti: jti}) do
    with true <- user_id == conn.assigns.current_user.id,
         session_jti when is_binary(session_jti) <-
           Token.peeked_jti(get_session(conn, "user_token")),
         true <- Plug.Crypto.secure_compare(session_jti, jti) do
      :ok
    else
      _ -> {:error, :invalid}
    end
  end

  # nil == nil included: a click on a node with no id, answered by one with
  # none either, can't be told apart (an unpinned row then serves whatever
  # file of its name is here).
  defp same_directory(%{dir_id: dir_id}) do
    if Backups.download_dir_id() == dir_id, do: :ok, else: {:error, :other_server}
  end

  # The path is `Backups.dir/0`, `Artifact.subdir/1` and a name matched against
  # the run's own row (`Run.Actions.Download`), never the client's string; the
  # body is an octet-stream attachment, never a document.
  # sobelow_skip ["Traversal.SendFile"]
  defp send_backup_file(conn, download) do
    Logger.info(
      "backup download user_id=#{conn.assigns.current_user.id} stamp=#{download.stamp} " <>
        "file=#{download.name} bytes=#{download.bytes}"
    )

    conn
    |> put_resp_content_type("application/octet-stream", nil)
    # The name is one of the row's, held by `Artifact.checked_files/2` to
    # `[a-z0-9.-]`, so it needs no quoting.
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{download.name}"))
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-robots-tag", "noindex")
    |> send_file(200, download.path, 0, download.bytes)
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

  defp answer(:method_not_allowed),
    do:
      {405, "method_not_allowed",
       gettext("Download a backup's files from the Backups page in the editor.")}

  defp answer(:forbidden),
    do: {403, "admin_required", gettext("Only a platform admin can download backup files.")}

  defp answer(:invalid),
    do:
      {403, "invalid_link",
       gettext(
         "This download link isn't valid for you. Go back to Backups and click Download again."
       )}

  defp answer(:expired),
    do:
      {410, "link_expired",
       gettext(
         "This download link has expired: it works for one minute. Go back to Backups and click Download again."
       )}

  defp answer(:console_shares_origin),
    do:
      {403, "console_shares_origin",
       gettext(
         "Downloads are off while the console shares its address with your organizations' sites. Set KILN_CONSOLE_HOST, or copy the files from the server."
       )}

  defp answer(reason)
       when reason == :other_server or
              (is_tuple(reason) and elem(reason, 0) in [:other_directory, :dir_id_unreadable]),
       do:
         {409, "other_server",
          gettext(
            "This link reached a different server than the page that made it. Download the file on the server that has it, or route /editor/backups to one server."
          )}

  defp answer(reason)
       when reason == :in_progress or (is_tuple(reason) and elem(reason, 0) == :lock_unreadable),
       do:
         {409, "in_progress",
          gettext("This backup is still being written. Download it once it has finished.")}

  defp answer(:audit_failed),
    do:
      {503, "audit_failed",
       gettext(
         "The download wasn't recorded in the security log, so nothing was sent. Try again in a moment."
       )}

  # Everything about the file itself, and anything unforeseen: one answer.
  defp answer(_not_found),
    do: {404, "not_found", gettext("That backup file isn't available for download.")}
end
