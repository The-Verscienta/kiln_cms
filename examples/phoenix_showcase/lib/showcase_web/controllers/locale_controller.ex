defmodule ShowcaseWeb.LocaleController do
  @moduledoc """
  Persists the visitor's chosen content locale in the session, then returns them
  where they were. The offered locales come from KilnCMS via `GET /api/locales`.
  """
  use ShowcaseWeb, :controller

  def update(conn, %{"locale" => locale} = params) do
    conn =
      case Showcase.Kiln.locales() do
        {:ok, %{locales: locales}} ->
          if locale in locales, do: put_session(conn, "locale", locale), else: conn

        _ ->
          conn
      end

    redirect(conn, to: safe_return_to(params))
  end

  # Only same-site absolute paths are honoured, so `return_to` can't be used as
  # an open redirect.
  defp safe_return_to(%{"return_to" => "/" <> _ = path}) do
    if String.starts_with?(path, "//"), do: "/", else: path
  end

  defp safe_return_to(_params), do: "/"
end
