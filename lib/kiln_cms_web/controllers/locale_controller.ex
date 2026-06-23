defmodule KilnCMSWeb.LocaleController do
  @moduledoc """
  Sets the UI locale preference in the session (used by the admin language
  switcher). LiveViews read it back via the `:restore_locale` on_mount hook.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.I18n

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
  # referring same-site path, else the editor. Only same-site paths are allowed.
  defp return_to(_conn, %{"return_to" => "/" <> _ = path}), do: path

  defp return_to(conn, _params) do
    with [referer] <- get_req_header(conn, "referer"),
         %URI{host: host, path: "/" <> _ = path} <- URI.parse(referer),
         true <- host == conn.host do
      path
    else
      _ -> ~p"/editor"
    end
  end
end
