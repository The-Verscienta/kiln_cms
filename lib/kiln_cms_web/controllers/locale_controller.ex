defmodule KilnCMSWeb.LocaleController do
  @moduledoc """
  Sets the UI locale preference in the session (used by the admin language
  switcher). LiveViews read it back via the `:restore_locale` on_mount hook.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.I18n
  alias KilnCMSWeb.SafeRedirect

  def update(conn, %{"locale" => locale} = params) do
    conn =
      if I18n.supported?(locale) do
        put_session(conn, "locale", locale)
      else
        conn
      end

    redirect(conn, to: return_to(conn, params))
  end

  # Return to where the user was: an explicit local `return_to`, else the
  # referring same-site path, else the editor. Only same-origin local paths are
  # allowed — `SafeRedirect` rejects `//evil.com` and other off-site targets.
  defp return_to(_conn, %{"return_to" => path}) when is_binary(path),
    do: SafeRedirect.local_path(path, ~p"/editor")

  defp return_to(conn, _params) do
    with [referer] <- get_req_header(conn, "referer"),
         %URI{host: host, path: path} when is_binary(path) <- URI.parse(referer),
         true <- host == conn.host,
         true <- SafeRedirect.safe_local_path?(path) do
      path
    else
      _ -> ~p"/editor"
    end
  end
end
