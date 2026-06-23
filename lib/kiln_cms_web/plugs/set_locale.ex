defmodule KilnCMSWeb.Plugs.SetLocale do
  @moduledoc """
  Resolves the request locale from a leading path segment.

  A known-locale prefix (`/fr/about`, `/en/blog/x`) is stripped from the path —
  so the normal routes match the remainder — and the locale is stashed in
  `conn.assigns.locale`. Requests without a recognised prefix use the default
  locale. The Gettext locale is set too, so UI strings localise once templates
  are wrapped.

  Runs in the endpoint before the router, so a single set of routes serves every
  locale.
  """
  @behaviour Plug

  import Plug.Conn

  alias KilnCMS.I18n

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    {locale, conn} = pop_locale(conn)
    Gettext.put_locale(KilnCMSWeb.Gettext, locale)
    assign(conn, :locale, locale)
  end

  # Strip a leading supported-locale segment (only when something follows it, so
  # a one-segment path like `/fr` is still treated as a slug, not a bare locale).
  defp pop_locale(%Plug.Conn{path_info: [seg | rest]} = conn) when rest != [] do
    if I18n.supported?(seg) do
      {seg, %{conn | path_info: rest, request_path: "/" <> Enum.join(rest, "/")}}
    else
      {I18n.default_locale(), conn}
    end
  end

  defp pop_locale(conn), do: {I18n.default_locale(), conn}
end
