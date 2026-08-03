defmodule KilnCMSWeb.SessionCookie do
  @moduledoc """
  The session cookie's whole shape, and the one rule that governs the names of
  every cookie Kiln authenticates with.

  Kiln serves every organization as a sibling host under a single registrable
  domain (`<slug>.<base_host>`, epic #336). A cookie set without a `Domain`
  attribute is host-scoped for *reads*, but RFC 6265 places no such limit on
  *writes*: script running on any `*.<base_host>` origin can set a cookie for
  the parent domain, and the browser then sends it to every sibling. That is
  cross-tenant session fixation, and the origins that can run script are not
  hypothetical — a stored XSS on the attacker's own tenant, a dangling
  subdomain, or #490's per-org code injection, which puts an org admin's script
  there by design.

  Two cookies of one name reach the server in the same `Cookie` header, and
  which one is honoured is not the coin-flip it looks like. `Plug.Conn.Cookies`
  builds its map so that the **first** pair in the header wins, and RFC 6265
  §5.4 sends longer `Path`s first. So the attacker does not race the victim's
  session — they outrank it, with `Domain=.<base_host>; Path=/editor`, which
  sorts ahead of the victim's `Path=/` on exactly the authoring routes worth
  taking. Simply planting the cookie in a browser that has no session yet works
  too, and outlives sign-out, because nothing on the server ever deletes a
  cookie it did not set.

  The `__Host-` prefix closes all of that at the source rather than at the tie:
  the browser refuses to *store* a cookie of that name unless it is `Secure`,
  has `Path=/`, and carries **no** `Domain`, so the sibling origin's write is
  rejected before it is ever sent. That is exactly the shape below, so the
  prefix costs nothing — except that it cannot be used without `Secure`, and
  dev, test and e2e run over plain HTTP. Hence the rule: the prefix rides the
  same `:secure_session_cookie` flag as `Secure` itself, in one expression, so
  the two cannot drift apart and leave the browser silently discarding every
  session. (Some browsers do accept `Secure` on `http://localhost`; Safari and
  any non-localhost HTTP dev host do not, so the bare name is what the
  non-production envs can rely on.)

  ## The rule covers remember-me too (#699)

  A second cookie that signs a request in is a second cookie a sibling origin
  can plant, and the remember-me token is the *better* prize: thirty days rather
  than a browser session, and it needs no pre-existing session on the target
  host — `sign_in_with_remember_me` runs ahead of `load_from_session`, so
  planting one signs the victim in as the attacker on their next page load.

  So `remember_me_key/1` rides the same flag, and `KilnCMSWeb.AuthController`
  overrides AshAuthentication's cookie writer to pair it with the attributes the
  prefix requires. The library's default writer hardcodes `secure: Mix.env() !=
  :dev` with no prefix and no explicit `path`, which is exactly the shape #686
  closed for the session cookie.

  The name is an **atom** because `remember_me`'s DSL takes one, and it is read
  back on the *read* path from that same DSL value — so setting it here is what
  makes both ends agree. A prefixed name written by the controller but read
  under the bare name would fail open: the browser would send nothing, and every
  remembered user would silently stop being remembered.

  See #686, #699 and `docs/threat-model.md`.
  """

  @base "_kiln_cms_key"
  @remember_me_base "remember_me"
  @host_prefix "__Host-"

  @doc """
  The session cookie name for a given `Secure` setting.

  `true` (production) yields the `__Host-`-prefixed name; `false` (dev, test,
  e2e — plain HTTP) yields the bare name.

      iex> KilnCMSWeb.SessionCookie.key(true)
      "__Host-_kiln_cms_key"

      iex> KilnCMSWeb.SessionCookie.key(false)
      "_kiln_cms_key"
  """
  @spec key(boolean()) :: String.t()
  def key(true), do: @host_prefix <> @base
  def key(false), do: @base

  @doc """
  The remember-me cookie name for a given `Secure` setting, as an atom.

  An atom because `remember_me`'s `cookie_name` DSL option takes one, and that
  DSL value is what the *read* path keys on — see the moduledoc.

      iex> KilnCMSWeb.SessionCookie.remember_me_key(true)
      :"__Host-remember_me"

      iex> KilnCMSWeb.SessionCookie.remember_me_key(false)
      :remember_me
  """
  @spec remember_me_key(boolean()) :: atom()
  def remember_me_key(true), do: :"#{@host_prefix}#{@remember_me_base}"
  def remember_me_key(false), do: :"#{@remember_me_base}"

  @doc """
  The `Plug.Session` options for a given `:secure_session_cookie` setting.

  The whole cookie lives here rather than in `KilnCMSWeb.Endpoint` so that the
  production shape — which no non-production build ever constructs — can be
  asserted directly: `options(true)` is what a release emits, whatever the
  compiling environment.

  The session is signed (tamper-proof) *and* encrypted, so its contents are not
  readable client-side either — defense-in-depth for anything put in the session
  (#217). Both salts derive keys from `secret_key_base`; rotating that
  invalidates existing sessions.

  A non-boolean raises rather than being coerced. It is read through
  `Application.compile_env/3`, so this fails the build — but a downstream
  overlay's `config/project.exs` is loaded last and could reasonably wire the
  flag to `System.get_env/1`, and `"false"` is truthy: coercing it would pair
  `Secure` with the *bare* name, which is the one combination this module exists
  to make impossible.
  """
  @spec options(term()) :: keyword()
  def options(secure?) do
    if is_boolean(secure?) do
      [
        store: :cookie,
        key: key(secure?),
        signing_salt: "Dsoh9oKb",
        encryption_salt: "8fso5iqxDfI",
        same_site: "Lax",
        http_only: true,
        # `__Host-` is honoured only at `Path=/` and only without a `Domain`.
        # Pinned rather than inherited from Plug's default, so a later edit has
        # to state the intent to break it.
        path: "/",
        secure: secure?
      ]
    else
      raise ArgumentError, """
      config :kiln_cms, :secure_session_cookie must be a boolean, got: #{inspect(secure?)}

      It sets both the session cookie's `Secure` attribute and its `__Host-`
      prefix, which browsers only honour together. A non-boolean cannot be
      coerced safely: any non-empty string is truthy, so "false" would mark the
      cookie `Secure` under the unprefixed name (#686).
      """
    end
  end
end
