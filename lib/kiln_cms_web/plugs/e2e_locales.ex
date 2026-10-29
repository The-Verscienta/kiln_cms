defmodule KilnCMSWeb.Plugs.E2ELocales do
  @moduledoc """
  Sets the deployment's content locales (`KilnCMS.I18n.locales/0`) for the
  browser E2E suite.

  `config/e2e.exs` inherits the single-locale default from `config/config.exs`,
  and specs such as `e2e/tests/status_marks.spec.js` assume a single-locale
  site. Only `e2e/tests/field_localization.spec.js` needs a second locale to
  translate into. It sets `["en", "fr"]` here before it opens the editor and
  puts the previous list back afterwards. With no chain configured for `fr`,
  `KilnCMS.I18n.Fallback` falls back to the default locale, which is the
  `fr → en` chain the spec relies on.

  The setting is VM-global and read on every request, so it applies to
  whatever runs while it is set. That is safe only because the suite runs one
  spec at a time (`workers: 1`).

  `POST` with `locales` as a list of locale tags that includes the default
  locale. The answer is `{"locales": new, "was": previous}`, and the caller
  restores `was`. Mounted only inside the router's compile-gated dev-tools
  scope, like `KilnCMSWeb.Plugs.E2ECollab`, which `KilnCMS.Application`
  refuses in `:prod`. That scope runs `protect_from_forgery`, so the spec calls
  it from a signed-in page with the page's CSRF token.
  """

  @behaviour Plug

  import Plug.Conn

  alias KilnCMS.I18n

  # The `KilnCMS.I18n.language_name/1` shape: a guard on what reaches the
  # config, not a BCP 47 parser.
  @tag_shape ~r/\A[a-z]{2,8}(?:-[A-Za-z0-9]{1,8}){0,2}\z/

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    with locales when is_list(locales) and locales != [] <- conn.params["locales"],
         true <- Enum.all?(locales, &(is_binary(&1) and Regex.match?(@tag_shape, &1))),
         true <- I18n.default_locale() in locales do
      was = I18n.locales()
      locales = Enum.uniq(locales)

      config = Application.get_env(:kiln_cms, :i18n, [])
      Application.put_env(:kiln_cms, :i18n, Keyword.put(config, :locales, locales))
      reply(conn, 200, %{locales: locales, was: was})
    else
      _other ->
        reply(conn, 400, %{
          error: "locales must be a list of locale tags including #{I18n.default_locale()}"
        })
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_header("allow", "POST")
    |> reply(405, %{error: "POST only"})
  end

  defp reply(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
