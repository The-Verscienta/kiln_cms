defmodule KilnCMS.Security.AuthEvents do
  @moduledoc """
  The sign-in and second-factor emit sites of the security audit log (#2241)
  share this module, so the request context, the org and the "never break the
  sign-in" rule are written once.

  ## Context

  `context/2` builds the map an emit site carries: the request context
  (`KilnCMS.Security.Recorder.context/1`) plus the org the request resolved to,
  under `KilnCMS.Security.Recorder.tenant_key/0`. A sign-in action is a read on
  the global `User`, with no tenant of its own, so the org travels in the Ash
  `context:`; `KilnCMSWeb.Plugs.SecurityContext` puts it there for the HTTP
  doors, and the sign-in LiveView merges it into its form context.

  ## Never an oracle, never a failure

  Every function is best-effort and returns `:ok`: a recorder fault is logged
  and counted, never raised into the sign-in it reports on. An unknown address
  produces an event with no actor and no label (`Recorder` drops both for a
  `nil` user), and the same two queries and one insert run whether or not the
  address has an account, so the work behind a refusal does not depend on it.

  ## One lockout, one event

  A locked account refuses every attempt until its window rolls. Writing an
  event per refusal would let the attacker fill the log, so `locked/5` records
  the first refusal of each subject and scope per window and drops the rest
  (counted on `[:kiln_cms, :security, :event_sampled_out]`).
  """

  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Security.Recorder

  @lock_bucket "security_sign_in_locked"
  @lock_window :timer.minutes(15)

  @doc """
  The context map for `source` (a `Plug.Conn`, or a LiveView socket during
  mount). `org` overrides the org read from the source's `current_org` assign;
  it may be an organization or an id.
  """
  @spec context(Plug.Conn.t() | Phoenix.LiveView.Socket.t() | map(), term()) :: map()
  def context(source, org \\ nil) do
    Map.put(Recorder.context(source), Recorder.tenant_key(), org_id(org) || org_id(source))
  end

  # A conn or socket first: a socket has an `id` of its own that is not an org's.
  defp org_id(%{assigns: %{current_org: %{id: id}}}) when is_binary(id), do: id
  defp org_id(%{assigns: _assigns}), do: nil
  defp org_id(%{id: id}) when is_binary(id), do: id
  defp org_id(id) when is_binary(id), do: id
  defp org_id(_other), do: nil

  @doc """
  The `metadata.method` a strategy's `AshAuthentication` activity signs in with:
  `{:password, :sign_in}` is `"password"`, `{:magic_link, _}` `"magic_link"`, a
  site's or the operator's identity provider `"sso"`.
  """
  @spec method(term()) :: String.t()
  def method({:password, :reset}), do: "password_reset"
  def method({:site_sso, _phase}), do: "sso"
  def method({:sso, _phase}), do: "sso"
  def method({strategy, _phase}) when is_atom(strategy), do: Atom.to_string(strategy)
  def method(_other), do: "other"

  @doc "A sign-in completed (every factor). `source` is the conn it completed on."
  @spec signed_in(Plug.Conn.t(), Accounts.User.t(), String.t()) :: :ok
  def signed_in(%Plug.Conn{} = conn, user, method) do
    safe(:sign_in, fn ->
      Recorder.record_after_commit(
        :sign_in,
        [user: user, metadata: %{"method" => method}] ++ opts(context(conn))
      )
    end)
  end

  @doc """
  A sign-in held, or refused, for want of the second factor its site requires
  (#2247). Recorded by the sign-in doors only, once per sign-in: never per
  request a held session makes afterwards, which would be an unbounded write.

  `surface` is `"browser"` or `"api"`; `reason` is `"not_enrolled"` (sent to
  set one up), `"passkey_host"` (a passkey-only account's password on a host
  where the passkey cannot run) or `"headless_passkey"` (the same at
  `POST /api/auth/sign_in`). `context` is an action context
  (`context/2`), which names the site.
  """
  @spec second_factor_required(map(), Accounts.User.t(), String.t(), String.t()) :: :ok
  def second_factor_required(context, %Accounts.User{} = user, surface, reason) do
    safe(:second_factor_required, fn ->
      tenant = context[Recorder.tenant_key()]

      if is_binary(tenant) do
        tier = KilnCMS.Accounts.Scoping.effective_tier(user, tenant)

        Recorder.record_after_commit(
          :second_factor_required,
          [
            user: user,
            metadata: %{"tier" => to_string(tier), "surface" => surface, "reason" => reason}
          ] ++ opts(context)
        )
      end
    end)
  end

  @doc """
  A refused sign-in (sampled per IP). `email` is only used to find the account
  when there is one; an address with none records no actor and no label.
  """
  @spec sign_in_failed(map(), term(), String.t(), String.t()) :: :ok
  def sign_in_failed(context, email, method, reason) do
    safe(:sign_in_failed, fn ->
      if is_binary(context[Recorder.tenant_key()]) do
        Recorder.record_sampled(
          :sign_in_failed,
          [
            # Lazy: a sampled-out event costs no read (a guessing flood must not
            # become a read per attempt).
            user: fn -> lookup(email, context[Recorder.tenant_key()]) end,
            metadata: %{"method" => method, "reason" => reason}
          ] ++ opts(context)
        )
      end
    end)
  end

  @doc """
  A refused second factor for `user` (a TOTP or recovery code that did not
  verify). The account is known here, a signed pending token named it.
  """
  @spec second_factor_failed(map(), Accounts.User.t()) :: :ok
  def second_factor_failed(context, user) do
    safe(:sign_in_failed, fn ->
      Recorder.record_sampled(
        :sign_in_failed,
        [
          user: fn -> member_of(user, context[Recorder.tenant_key()]) end,
          metadata: %{"method" => "second_factor", "reason" => "invalid_code"}
        ] ++ opts(context)
      )
    end)
  end

  @doc """
  A lockout began. `subject` is what the lock keys on (an email for a password
  lock, a user for a second-factor one, an ip for an address lock) and `scope`
  names it: `"account"`, `"address"`, `"second_factor"` or `"settings"`. Only
  the first refusal per subject and scope each window is written.

  `user` is the account when it is known; an unknown address locks without one.
  """
  @spec locked(map(), Accounts.User.t() | nil, String.t(), String.t(), term()) :: :ok
  def locked(context, user, method, scope, subject) do
    safe(:sign_in_locked, fn ->
      tenant = context[Recorder.tenant_key()]

      if is_binary(tenant) and first_this_window?(tenant, scope, subject) do
        Recorder.record_after_commit(
          :sign_in_locked,
          [
            user: fn -> member_of(user, tenant) end,
            metadata: %{"method" => method, "scope" => scope}
          ] ++ opts(context)
        )
      end
    end)
  end

  @doc "`locked/5` for a password lock on `email`: the account is looked up, if it exists."
  @spec password_locked(map(), term(), String.t()) :: :ok
  def password_locked(context, email, "address" = scope) do
    locked(context, nil, "password", scope, get_in(context, [:security_request, :ip]) || email)
  end

  def password_locked(context, email, scope) do
    safe(:sign_in_locked, fn ->
      if is_binary(context[Recorder.tenant_key()]),
        do: locked(context, account(email), "password", scope, email),
        else: :ok
    end)
  end

  @doc """
  An unlock link was mailed (#2250). Only ever called once the mail is queued,
  off the request path, so the log names no address that was not mailed. The
  account is labelled only when it belongs to the request's site.
  """
  @spec sign_in_unlock_requested(map(), Accounts.User.t()) :: :ok
  def sign_in_unlock_requested(context, user) do
    safe(:sign_in_unlock_requested, fn ->
      tenant = context[Recorder.tenant_key()]

      if is_binary(tenant) do
        Recorder.record_after_commit(
          :sign_in_unlock_requested,
          [user: fn -> member_of(user, tenant) end, metadata: %{"surface" => "browser"}] ++
            opts(context)
        )
      end
    end)
  end

  @doc "An unlock link lifted a sign-in pause (#2250). `was_locked` is whether one was on."
  @spec sign_in_unlocked(map(), Accounts.User.t(), boolean()) :: :ok
  def sign_in_unlocked(context, user, was_locked) do
    safe(:sign_in_unlocked, fn ->
      tenant = context[Recorder.tenant_key()]

      if is_binary(tenant) do
        Recorder.record_after_commit(
          :sign_in_unlocked,
          [
            user: fn -> member_of(user, tenant) end,
            metadata: %{"was_locked" => to_string(was_locked)}
          ] ++ opts(context)
        )
      end
    end)
  end

  @doc """
  An unlock link was refused (#2250), sampled per IP like a failed sign-in.
  `user` is the account a *verified* link names, or nil; it is labelled only
  when it belongs to the request's site.
  """
  @spec sign_in_unlock_refused(map(), Accounts.User.t() | nil, String.t()) :: :ok
  def sign_in_unlock_refused(context, user, reason) do
    safe(:sign_in_unlock_refused, fn ->
      tenant = context[Recorder.tenant_key()]

      if is_binary(tenant) do
        Recorder.record_sampled(
          :sign_in_unlock_refused,
          [user: fn -> member_of(user, tenant) end, metadata: %{"reason" => reason}] ++
            opts(context)
        )
      end
    end)
  end

  defp opts(context) do
    [tenant: context[Recorder.tenant_key()], request: context[Recorder.context_key()]]
  end

  # The account, or nil, labelling only an account that belongs to `org`: the
  # address came from an anonymous request, and an account of another site must
  # neither appear in this site's log nor be confirmed by it.
  defp lookup(email, org), do: member_of(account(email), org)

  defp account(email) when is_binary(email) or is_struct(email, Ash.CiString) do
    # authorize?: false — a refused sign-in has no actor; the row only labels
    # the audit event, and nothing the caller sees depends on whether it exists.
    case Accounts.get_user_by_email(to_string(email), authorize?: false, not_found_error?: false) do
      {:ok, %Accounts.User{} = user} -> user
      _none -> nil
    end
  end

  defp account(_other), do: nil

  @doc """
  `user` when it belongs to `org`, else nil (recorded as unknown). Belonging
  is what `KilnCMS.Accounts.Scoping` decides: a membership on the org, or no
  membership anywhere on the default org (the legacy account). A platform
  admin with neither is not labelled either; the log is the site's own.

  Also the rule for who may be mailed a sign-in unlock link on a site (#2250).
  """
  @spec member_of(Accounts.User.t() | nil, term()) :: Accounts.User.t() | nil
  def member_of(%Accounts.User{id: user_id} = user, org) when is_binary(org) do
    # authorize?: false — the same membership reads Scoping makes to resolve a
    # tier; the answer only decides whether the audit event is labelled.
    case Accounts.get_org_membership(user_id, org, authorize?: false, not_found_error?: false) do
      {:ok, %{}} -> user
      _none -> if legacy_member?(user_id, org), do: user
    end
  end

  def member_of(_user, _org), do: nil

  defp legacy_member?(user_id, org) do
    # authorize?: false — the same legacy-account check Scoping makes; the answer
    # only decides whether the audit event is labelled.
    org == Accounts.default_org_id() and
      match?(
        {:ok, []},
        Accounts.list_memberships_for_user(user_id, authorize?: false, query: [limit: 1])
      )
  end

  defp first_this_window?(tenant, scope, subject) do
    key = "#{tenant}:#{scope}:#{AccountThrottle.digest(to_string(subject))}"

    case ThrottleStore.hit(@lock_bucket, key, @lock_window, 1) do
      {:allow, _count} ->
        true

      {:deny, _retry_after} ->
        :telemetry.execute([:kiln_cms, :security, :event_sampled_out], %{count: 1}, %{
          type: :sign_in_locked
        })

        false
    end
  end

  # The boundary: an audit write must never fail the sign-in it reports on.
  defp safe(type, fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error("security event #{type} not recorded: #{Exception.message(error)}")
      :telemetry.execute([:kiln_cms, :security, :event_failed], %{count: 1}, %{type: type})
      :ok
  catch
    :exit, reason ->
      Logger.error("security event #{type} not recorded: #{inspect(reason)}")
      :telemetry.execute([:kiln_cms, :security, :event_failed], %{count: 1}, %{type: type})
      :ok
  end
end
