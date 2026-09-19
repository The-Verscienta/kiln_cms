defmodule KilnCMSWeb.DeliveryLocale do
  @moduledoc """
  The locale half of a headless delivery request: reading `?locale=`,
  `?fallback=` and `?fallback_locale=`, refusing a locale the site does not
  serve, and saying on the response which locale was actually served.

  Shared by every hand-written delivery controller (artifacts, `/api/resolve`,
  `/api/menus`) and by the JSON:API `/by-slug/:slug` routes, so the four read
  one question the same way — the drift #751 was about.

  ## An unsupported locale is a `400`, not the default

  `?locale=de` on a site that does not run German used to mean four different
  things depending on the endpoint: the English document, a 404, the default
  menu. A typo (`fr_CA`) answered with English is indistinguishable from "no
  French translation", and a front end cannot fix what it cannot see, so every
  surface now answers `400 unsupported_locale` naming `GET /api/locales`. A
  *missing translation* in a supported locale is what the fallback chain is
  for (`KilnCMS.I18n.Fallback`).

  The same rule holds for `fallback_locale`. `fallback` takes `true`/`false`
  (or `1`/`0`); anything else is `400 invalid_fallback` rather than read as
  either, because both readings change which document is served.

  ## Which locale was served

  `put_served/2` sets `x-kiln-locale` and `Content-Language` to the record's
  own locale. The URL (and so every cache key in front of Kiln) carries the
  *requested* locale and the fallback parameters, so a shared cache never
  mixes two answers; the ETag of each surface folds the served locale in too.
  """
  import Plug.Conn

  alias KilnCMS.CMS.Preparations.LocaleFallback
  alias KilnCMS.I18n
  alias KilnCMS.I18n.Fallback
  alias KilnCMSWeb.ApiError

  @type request :: %{locale: String.t(), mode: Fallback.mode()}
  @type error :: {:error, String.t(), String.t()}

  @doc """
  The request's locale and fallback mode. `locale` defaults to the site's
  default locale; `fallback` defaults to `true` (the site's chain).
  """
  @spec parse(map()) :: {:ok, request()} | error()
  def parse(params) when is_map(params) do
    with {:ok, locale} <- locale(params, "locale", I18n.default_locale()),
         {:ok, fallback_locale} <- locale(params, "fallback_locale", nil),
         {:ok, fallback?} <- fallback(params) do
      {:ok, %{locale: locale, mode: LocaleFallback.mode(fallback?, fallback_locale)}}
    end
  end

  @doc "Answer a `parse/1` error with the `KilnCMSWeb.ApiError` envelope."
  @spec send_error(Plug.Conn.t(), error()) :: Plug.Conn.t()
  def send_error(conn, {:error, code, message}),
    do: ApiError.send(conn, :bad_request, code, message)

  @doc """
  `x-kiln-locale` and `Content-Language` for the locale actually served. A
  no-op for `nil`, so a caller can pipe a record that may lack one.
  """
  @spec put_served(Plug.Conn.t(), String.t() | nil) :: Plug.Conn.t()
  def put_served(conn, locale) when is_binary(locale) do
    conn
    |> put_resp_header("x-kiln-locale", locale)
    |> put_resp_header("content-language", locale)
  end

  def put_served(conn, _locale), do: conn

  @doc """
  AshJsonApi's `modify_conn` hook for the `/by-slug/:slug` routes: the served
  locale is the returned record's own.
  """
  @spec modify_json_api_conn(Plug.Conn.t(), term(), term(), term()) :: Plug.Conn.t()
  def modify_json_api_conn(conn, _subject, %{locale: locale}, _request),
    do: put_served(conn, locale)

  def modify_json_api_conn(conn, _subject, _result, _request), do: conn

  # Not `KilnCMSWeb.Params.string/3`: a `?locale[]=fr` read as absent would be
  # served in the default locale, which is the silent substitution this module
  # exists to end. A wrong shape is refused like a wrong value.
  defp locale(params, key, default) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        if I18n.supported?(value),
          do: {:ok, value},
          else: unsupported(key, inspect(value))

      _other ->
        unsupported(key, "that value")
    end
  end

  defp unsupported(key, shown) do
    {:error, "unsupported_locale",
     "`#{key}`: #{shown} is not a locale this site serves. " <>
       "Supported: #{Enum.join(I18n.locales(), ", ")} (GET /api/locales)."}
  end

  defp fallback(params) do
    case Map.get(params, "fallback") do
      nil -> {:ok, true}
      value when value in ["true", "1"] -> {:ok, true}
      value when value in ["false", "0"] -> {:ok, false}
      _other -> {:error, "invalid_fallback", "`fallback` must be true or false."}
    end
  end
end
