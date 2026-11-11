defmodule KilnCMSWeb.SharedCache do
  @moduledoc """
  The rule for public HTML a shared cache may store (#2630): **a response
  marked `public` renders nothing from the session.**

  A CDN keys a `public, max-age` response on its URL and hands the body to
  every later visitor. Whatever the body carries from one visitor's session
  is then served to strangers. Two things could:

    * **The CSRF `<meta>`.** The root layout renders a per-session masked
      token. Masking limits the harm, but the token still belongs to one
      session, and minting it for a visitor without one writes the session,
      so the response also carried a `set-cookie`.
    * **The signed-in user.** `Layouts.public` renders Account and Sign out
      for a `current_user`, and a content template that passed one would put a
      reader's own links into the shared copy.

  Both are closed here, so no template has to remember:

    * `put_public/2` sets the shared `cache-control` and clears
      `:current_user` from the assigns the templates read. Every public HTML
      response goes through it rather than writing the header itself.
    * `shared?/1` is what the root layout asks before it renders the CSRF
      `<meta>` (`KilnCMSWeb.Layouts.csrf_token/1`). It reads the header, not a
      flag, so a response marked `public` some other way is covered too.

  Nothing a shared page renders needs the token. Its forms post to
  `:public_form` routes, which take no CSRF token (form blocks, the newsletter
  signup), and the pages mount no LiveView. A page that does need one, such as
  the passphrase lock page, is private (`private, no-store`) and keeps it.
  """

  import Plug.Conn

  @delivery "public, max-age=60, stale-while-revalidate=300"

  @doc """
  The `cache-control` for published HTML: a short shared `max-age` with a
  longer `stale-while-revalidate` window.
  """
  @spec delivery_cache_control() :: String.t()
  def delivery_cache_control, do: @delivery

  @doc """
  Mark `conn` as shared-cacheable HTML and clear what the session put in its
  assigns, so the render cannot carry it.

  Call it after every decision that read the user (audiences, variants, the
  lock), and before `render/3`.
  """
  @spec put_public(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_public(conn, cache_control \\ @delivery) do
    conn
    |> put_resp_header("cache-control", cache_control)
    |> assign(:current_user, nil)
  end

  @doc """
  Whether `conn`'s response is marked for a shared cache (`cache-control:
  public`). The root layout renders no CSRF token on such a response.
  """
  @spec shared?(Plug.Conn.t() | nil) :: boolean()
  def shared?(%Plug.Conn{} = conn) do
    conn
    |> get_resp_header("cache-control")
    |> Enum.any?(fn value ->
      value
      |> String.split(",")
      |> Enum.any?(&(&1 |> String.trim() |> String.downcase() == "public"))
    end)
  end

  def shared?(_no_conn), do: false
end
