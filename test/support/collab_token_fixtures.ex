defmodule KilnCMS.CollabTokenFixtures do
  @moduledoc """
  Collab socket tokens for the socket and channel tests (#2490): a token bound
  to a stored browser-session row, as `KilnCMSWeb.ContentEditorLive` mints in
  production, and the one legacy shape (no session) that is still accepted for
  a release.

  Every token here names a real token row, so the connect tests that refuse
  for another reason — an allowlist, an IP block, a strict host, a held
  second factor — exercise the path a real editor's socket takes, session
  check included.
  """

  alias KilnCMS.Accounts.Token

  @endpoint KilnCMSWeb.Endpoint

  @doc """
  Seed a session row for `user` and return its jti. Shaped like the row a
  password sign-in stores (purpose `"user"`, an hour to live); `attrs`
  overrides any of it (`org_id:` binds it to a site, `purpose:`,
  `expires_at:`, `jti:`).
  """
  def session!(user, attrs \\ %{}) do
    row =
      Ash.Seed.seed!(
        Token,
        Map.merge(
          %{
            jti: "collab-session-#{System.unique_integer([:positive])}",
            subject: AshAuthentication.user_to_subject(user),
            purpose: Token.user_purpose(),
            expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          },
          Map.new(attrs)
        )
      )

    row.jti
  end

  @doc """
  A collab token for `user` bound to a new session row (`session!/2`).
  Options: `:verified?` (the session passed a second factor) and `:session`
  (attributes for the row).
  """
  def collab_token(user, opts \\ []) do
    {token, _jti} = collab_token_and_jti(user, opts)
    token
  end

  @doc "`collab_token/2`, with the jti of the session row it is bound to."
  def collab_token_and_jti(user, opts \\ []) do
    jti = session!(user, Keyword.get(opts, :session, %{}))
    {KilnCMSWeb.CollabSocket.token(user, Keyword.get(opts, :verified?, false), jti), jti}
  end

  @doc """
  A token minted before #2490: `%{"u", "sf"}`, naming no session. Still
  accepted for one release, with per-user semantics.
  """
  def legacy_collab_token(user, verified? \\ false),
    do: Phoenix.Token.sign(@endpoint, "collab", %{"u" => user.id, "sf" => verified?})
end
