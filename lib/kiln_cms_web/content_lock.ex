defmodule KilnCMSWeb.ContentLock do
  @moduledoc """
  Where a visitor's passphrase unlocks live on the built-in site (#496).

  One signed, http-only cookie holds the grants this browser has earned. Each
  grant is a `KilnCMS.CMS.ContentPassword` token — self-expiring and naming a
  single document's current passphrase — so the cookie is only transport; the
  token is the credential. The headless surface carries exactly the same token
  in a header, which is why there is one format rather than two.

  ## The privacy claim this has to keep

  `docs/data-flows.md` states that Kiln records no cookie for visitors, and
  `KilnCMS.Analytics` and `KilnCMSWeb.ViewTracking` are built around that. This
  cookie does not break it, and the reason is worth being precise about rather
  than asserting:

    * it exists only because the visitor typed a passphrase — it is created by a
      deliberate act, never on a plain page view;
    * it carries no identifier of any kind. The contents are fingerprints of
      *documents' passphrases*, not of the visitor. Two people who unlock the
      same page hold byte-identical cookies, so it cannot distinguish them, and
      there is nothing in it to join to anything else;
    * nothing reads it except the unlock check, and no analytics counter is
      keyed on it.

  In other words it is strictly-necessary state for a feature the visitor asked
  for, which is the one category the no-tracking promise was never about.

  ## Bounds

  At most `@max_grants` grants are kept, newest first. A visitor who unlocks
  more documents than that silently loses the oldest and is re-prompted — the
  alternative is an unbounded header that eventually breaks the request.
  """

  import Plug.Conn

  alias KilnCMS.CMS.ContentPassword

  @cookie "_kiln_unlock"
  @max_grants 8

  @doc """
  Every unexpired fingerprint this request carries, ready to hand to a delivery
  read's `:unlocks` argument.

  Anything unreadable — tampered, expired, from a previous `secret_key_base` —
  is dropped silently rather than raising: a stale cookie should re-prompt for
  the passphrase, not 500 the page.
  """
  @spec grants(Plug.Conn.t()) :: [String.t()]
  def grants(conn) do
    conn
    |> tokens()
    |> Enum.flat_map(fn token ->
      case ContentPassword.verify_grant(token) do
        {:ok, fingerprint} -> [fingerprint]
        {:error, _} -> []
      end
    end)
  end

  @doc """
  Record a verified unlock for `fingerprint` and return the updated conn.

  The grant replaces any existing one for the same fingerprint (so re-entering a
  passphrase refreshes the clock rather than stacking duplicates), and the list
  is capped at `#{@max_grants}`.
  """
  @spec grant(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def grant(conn, fingerprint) when is_binary(fingerprint) do
    kept =
      conn
      |> tokens()
      |> Enum.reject(&(ContentPassword.verify_grant(&1) == {:ok, fingerprint}))

    tokens = Enum.take([ContentPassword.sign(fingerprint) | kept], @max_grants)

    put_resp_cookie(conn, @cookie, tokens,
      sign: true,
      http_only: true,
      same_site: "Lax",
      secure: conn.scheme == :https,
      max_age: ContentPassword.max_age_seconds()
    )
  end

  @doc "The cookie name, for tests and for the docs to name one thing."
  @spec cookie_name() :: String.t()
  def cookie_name, do: @cookie

  defp tokens(conn) do
    conn = fetch_cookies(conn, signed: [@cookie])

    case conn.cookies[@cookie] do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _absent_or_tampered -> []
    end
  end
end
