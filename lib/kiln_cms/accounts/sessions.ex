defmodule KilnCMS.Accounts.Sessions do
  @moduledoc """
  An account's own signed-in sessions, for the settings page (#1823): list
  them, sign one out, sign out all but this one.

  ## What a session is

  A browser session is a stored `"user"` token (`KilnCMS.Accounts.Token`).
  `require_token_presence_for_authentication?` is on, so every request and
  every LiveView mount looks the row up by the jti in the session cookie; a row
  whose purpose is no longer `"user"` signs that cookie out. That makes the row
  the session, and revoking the row the sign-out — on that browser's next
  request, wherever it is.

  Two things outlive a revoked row, and both are handled here:

    * **The remember-me cookie.** It is a complete sign-in on its own, and it
      is only read when the session names no token — a revoked session that
      later loses its session cookie (a browser restart) would be signed
      straight back in by it. The sign-in records the cookie's jti on the
      session row (`remember_me_jti`, by `KilnCMSWeb.Plugs.SessionTracking`),
      and signing the session out revokes both.
    * **The LiveViews already mounted.** They authorized at mount. Each one
      listens on its session's topic (`KilnCMSWeb.SessionTracking`), and
      `KilnCMS.Accounts.SessionEviction.evict_session/2` sends them to sign-in;
      the rejoin finds the token gone.

  ## Authorization

  Listing and revoking run as the account (`actor:`), through
  `KilnCMS.Accounts.Checks.OwnsToken`: a jti naming another account's session
  matches no row and revokes nothing. Admins get no wider view here — they
  sign an account out everywhere from the Accounts page.

  The two `record_*` writes are bookkeeping keyed by a jti read from the signed
  session, with no actor to ask, and run with `authorize?: false`; their actions
  are `forbid_if always()` for every other caller. They never raise: a failure
  to note when a session was last used must not fail the page.
  """
  require Ash.Query
  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Token

  # The `record_*` writes: one atomic UPDATE keyed by jti, errors returned
  # rather than raised.
  # authorize?: false — session bookkeeping has no actor; both actions forbid every caller
  @bookkeeping [authorize?: false, bulk_options: [strategy: :atomic, return_errors?: true]]

  @doc "The account's own active sessions, most recently used first."
  @spec list(struct()) :: [Token.t()]
  def list(user) do
    case Accounts.list_own_sessions(actor: user) do
      {:ok, sessions} -> sessions
      {:error, _error} -> []
    end
  end

  @doc """
  Sign out one of `user`'s sessions by its jti: the session, the remember-me
  cookie issued with it, and its open LiveViews.

  `{:error, :not_found}` for a jti that is not one of `user`'s active
  sessions — someone else's included, which is indistinguishable on purpose.
  """
  @spec revoke(struct(), String.t()) :: :ok | {:error, :not_found | term()}
  def revoke(user, jti) when is_binary(jti) do
    with {:ok, session} <- fetch_own(user, jti),
         jtis = [session.jti | List.wrap(session.remember_me_jti)],
         {:ok, _revoked} <- revoke_rows(user, Ash.Query.filter(Token, jti in ^jtis)) do
      SessionEviction.evict_session(session.jti, :signed_out_by_owner)
    end
  end

  def revoke(_user, _jti), do: {:error, :not_found}

  @doc """
  Sign out every one of `user`'s sessions except `current_jti` — this one — and
  every remember-me cookie except the one issued to this browser. A sign-in
  waiting at the two-factor prompt elsewhere ends with them.

  Returns how many sessions were signed out.
  """
  @spec revoke_others(struct(), String.t() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_others(user, current_jti) do
    keep =
      case current_jti && fetch_own(user, current_jti) do
        {:ok, current} -> Enum.reject([current.jti, current.remember_me_jti], &is_nil/1)
        _none -> List.wrap(current_jti)
      end

    # Counted from the list rather than from the revoked rows, which all read
    # "revocation" once revoked and no longer say which were sessions.
    others = user |> list() |> Enum.count(&(&1.jti not in keep))

    with {:ok, revoked} <- revoke_rows(user, Ash.Query.filter(Token, jti not in ^keep)) do
      # Every revoked jti, sessions and cookies alike: a remember-me row has no
      # LiveViews, and a broadcast nobody listens to costs nothing.
      Enum.each(revoked, &SessionEviction.evict_session(&1.jti, :signed_out_by_owner))
      {:ok, others}
    end
  end

  @doc """
  Stamp a session at sign-in: the browser it signed in from, the site it
  signed in on (#2246), and the remember-me cookie issued with it — which is
  stamped with the same site and noted as just used. Best-effort.
  """
  @spec record_sign_in(String.t(), map(), String.t() | nil, Ash.UUID.t() | nil, String.t() | nil) ::
          :ok
  def record_sign_in(
        jti,
        %{browser: browser, platform: platform},
        remember_me_jti,
        org_id \\ nil,
        subject \\ nil
      )
      when is_binary(jti) do
    args = %{
      browser: browser,
      platform: platform,
      remember_me_jti: remember_me_jti,
      org_id: org_id
    }

    record(fn -> Accounts.record_session_sign_in(by_jti(jti), args, @bookkeeping) end)

    if is_binary(remember_me_jti) and is_binary(org_id) and is_binary(subject) do
      bind_to_site([remember_me_jti], org_id, subject)
    end

    :ok
  end

  @doc """
  Bind the rows `jtis` (sessions or remember-me cookies) of the account
  `subject` to the site `org_id` and note their use now — unless one belongs
  to another account, is already bound to another site, or predates the
  site's last "sign out everyone" (#2246). Best-effort.
  """
  @spec bind_to_site([String.t()], Ash.UUID.t(), String.t()) :: :ok
  def bind_to_site(jtis, org_id, subject)
      when is_list(jtis) and is_binary(org_id) and is_binary(subject) do
    record(fn ->
      Accounts.bind_sessions_to_site(
        Ash.Query.filter(Token, jti in ^jtis),
        %{org_id: org_id, subject: subject},
        @bookkeeping
      )
    end)
  end

  @doc """
  Note that a session — and the remember-me row named with it — was used just
  now on the site `org_id`. Writes at most once per `:interval_seconds`
  (default `Token.last_used_interval_minutes/0`); the rest match no row, and a
  row stamped for another site is never touched (#2246). Best-effort.

  Options: `:org_id` (required) and `:interval_seconds`.
  """
  @spec record_use(String.t() | [String.t()], map(), keyword()) :: :ok
  def record_use(jtis, labels, opts) do
    jtis = List.wrap(jtis)
    org_id = Keyword.fetch!(opts, :org_id)

    args =
      %{
        browser: Map.get(labels, :browser),
        platform: Map.get(labels, :platform),
        org_id: org_id
      }
      |> maybe_put(:interval_seconds, Keyword.get(opts, :interval_seconds))

    record(fn ->
      Accounts.record_session_use(Ash.Query.filter(Token, jti in ^jtis), args, @bookkeeping)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Sign out every session, remember-me cookie and held two-factor sign-in
  stamped for the site `org_id`, except the rows in `keep` (#2246). Run by
  `KilnCMS.Accounts.SignOutAll`, inside its transaction and after its
  authorization; drops nothing live itself.

  Returns `{:ok, sessions, others}`: the revoked session rows (purpose
  `"user"`) and every other revoked row.
  """
  @spec revoke_org(Ash.UUID.t(), [String.t()]) ::
          {:ok, [Token.t()], [Token.t()]} | {:error, term()}
  def revoke_org(org_id, keep) when is_binary(org_id) and is_list(keep) do
    user_purpose = Token.user_purpose()

    # Two statements so the sessions can be counted and their pages closed:
    # once revoked, every row reads "revocation" and no longer says what it was.
    with {:ok, sessions} <-
           revoke_org_rows(Ash.Query.filter(Token, purpose == ^user_purpose), org_id, keep),
         {:ok, others} <-
           revoke_org_rows(Ash.Query.filter(Token, purpose != ^user_purpose), org_id, keep) do
      {:ok, sessions, others}
    end
  end

  defp revoke_org_rows(query, org_id, keep) do
    # authorize?: false — "sign out everyone" has already been authorized as an
    # org admin by `SiteSessionPolicy.sign_out_all`; the action is scoped to the
    # tenant's own rows by its filter and forbids every other caller.
    case Accounts.revoke_org_sessions(query, %{org_id: org_id, keep: keep},
           authorize?: false,
           bulk_options: [strategy: :atomic, return_records?: true, return_errors?: true]
         ) do
      %Ash.BulkResult{status: :success, records: records} -> {:ok, records || []}
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  # --- internals ---------------------------------------------------------------

  defp fetch_own(user, jti) do
    case Accounts.get_own_session(jti, actor: user, not_found_error?: false) do
      {:ok, %Token{} = session} -> {:ok, session}
      _missing -> {:error, :not_found}
    end
  end

  defp revoke_rows(user, query) do
    case Accounts.revoke_own_sessions(query, %{},
           actor: user,
           bulk_options: [
             strategy: :atomic,
             # The rows are found through the actor's own tokens, so the
             # query half of the bulk update is authorized by the same
             # `OwnsToken` filter as the write.
             read_action: :own_tokens,
             return_records?: true,
             return_errors?: true
           ]
         ) do
      %Ash.BulkResult{status: :success, records: records} -> {:ok, records || []}
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  defp by_jti(jti), do: Ash.Query.filter(Token, jti == ^jti)

  defp record(write) do
    case write.() do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: errors} ->
        Logger.warning("Could not record session use: #{inspect(errors)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Could not record session use: #{Exception.message(error)}")
      :ok
  end
end
