defmodule KilnCMS.Accounts.IdleTimeout do
  @moduledoc """
  Signs a browser session out after a site's chosen stretch of inactivity, and
  enforces an admin's "sign out everyone" on sessions the bulk revocation could
  not name (#2246).

  ## The policy

  A site's `KilnCMS.CMS.SiteSessionPolicy` row: an idle timeout for everyone,
  a shorter one for its administrators, or neither (the default: off). The
  timeout that applies is the one of the site the request is on, and the
  account's tier **there**, recomputed at every check: an admin is held to the
  shorter of the two that are set, everyone else to the general one.

  The site decides (ADR 0018 lets a site only lower an operator ceiling, and
  there is no operator ceiling here). A row that cannot be read is logged and
  read as "off": the timeout fails open rather than signing every account out
  during a database blip. `policy/1` caches the answer for a minute; a save
  busts it on every node and tells the open pages of the site.

  ## Last activity

  `last_used_at` on the session's token row (and its remember-me row), written
  by the database's clock and compared with it — `Token.idle_seconds` and the
  `:expire_idle_session` UPDATE never use the node's clock. A write happens at
  most once per `touch_interval/1`, and the expiring UPDATE repeats the
  verdict in its WHERE, so a touch from another tab that lands first leaves
  the session alone.

  Idle is measured from the later of the last use and the moment the site last
  changed its timeout (`policy_changed_at`), so turning the timeout on, or
  shortening it, never signs anyone out for inactivity before the rule
  existed.

  ## Where a session is bound to a site

  A session and its remember-me cookie record the site they signed in on
  (`Token.org_id`). A row stamped for another site, arriving on this host, was
  copied here (the cookies are host-only): it is treated as signed out on this
  host and never touched, so it can neither be used here nor kept awake from
  here.

  ## What it costs

  The site's policy is one cached lookup. The cross-site rule needs the
  session's own token row, so every signed-in browser request and every
  signed-in LiveView mount reads that row (one primary-key read), whether or
  not the site has a timeout; a write follows at most once per
  `touch_interval/1` (five minutes when the site has no timeout).

  ## "Sign out everyone"

  `KilnCMS.Accounts.SignOutAll` revokes every row stamped for the site and
  records a watermark (`sessions_revoked_at`). A row signed in before the
  watermark and used on this site's host — one signed in before sessions
  recorded their site, or held at the two-factor prompt at the time — is
  revoked here when it is next seen, until the watermark is older than the
  longest-lived cookie. No write binds such a row to the site (the token
  actions read the watermark in the same statement), so it cannot escape by
  being used first.
  """
  require Ash.Query
  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SessionEviction
  alias KilnCMS.Accounts.Token
  alias KilnCMS.Security.Recorder

  defmodule Policy do
    @moduledoc """
    A site's resolved session policy (#2246): the two timeouts in seconds
    (`nil` when unset), when they last changed, and the last "sign out
    everyone". Never `nil` itself — the cache does not keep a `nil`, and "off"
    is an answer, not a failure.
    """
    defstruct idle_seconds: nil, admin_idle_seconds: nil, changed_at: nil, revoked_at: nil

    @type t :: %__MODULE__{
            idle_seconds: pos_integer() | nil,
            admin_idle_seconds: pos_integer() | nil,
            changed_at: DateTime.t() | nil,
            revoked_at: DateTime.t() | nil
          }
  end

  @ttl :timer.seconds(60)

  # The longest a cookie that predates a "sign out everyone" can still sign a
  # request in: the remember-me token's lifetime. Past it, the watermark has
  # nothing left to catch and the token read stops.
  @watermark_horizon_seconds 30 * 24 * 3600

  # How late the LiveView timer fires after the computed deadline, so the
  # re-read finds the session past it rather than a second short of it.
  @timer_slack_seconds 5

  @typedoc "What a check found."
  @type verdict ::
          {:active,
           %{
             timeout: pos_integer() | nil,
             remaining: integer() | nil,
             idle: integer() | nil,
             jtis: [String.t()]
           }}
          | {:signed_out, :idle | :admin_sign_out_all | :revoked | :foreign | :missing}
          | :error

  @doc "The PubSub topic a site's open signed-in pages hear policy changes on."
  @spec topic(Ash.UUID.t()) :: String.t()
  def topic(org_id) when is_binary(org_id), do: "session_policy:#{org_id}"

  @doc "The policy that means \"off\": no timeout, no watermark."
  @spec off() :: Policy.t()
  def off, do: %Policy{}

  @doc """
  The resolved policy of `org_id`, cached for a minute. An unreadable row is
  logged and answered `off/0`, uncached.
  """
  @spec policy(Ash.UUID.t() | nil) :: Policy.t()
  def policy(org_id) when is_binary(org_id) do
    actor = KilnCMS.OrgSettings.system(:accounts)

    KilnCMS.OrgSettings.resolve(org_id,
      cache_key: KilnCMS.Cache.session_policy_key(org_id),
      ttl: @ttl,
      read:
        &KilnCMS.CMS.list_site_session_policy(tenant: &1, actor: actor, authorize_with: :error),
      build: &from_row/1,
      fallback: &off/0,
      label: "session policy"
    )
  end

  def policy(_no_org), do: off()

  @doc """
  The policy of `org_id` read now, uncached, telling an unreadable row
  (`:error`) apart from "off": `policy/1` answers both `off/0`. For the
  Security posture page (#2252), which must not report a timeout it cannot
  see as one that is unset.
  """
  @spec read_policy(Ash.UUID.t()) :: {:ok, Policy.t()} | :error
  def read_policy(org_id) when is_binary(org_id) do
    actor = KilnCMS.OrgSettings.system(:accounts)

    case KilnCMS.OrgSettings.resolve_uncached(org_id,
           read:
             &KilnCMS.CMS.list_site_session_policy(
               tenant: &1,
               actor: actor,
               authorize_with: :error
             ),
           build: &from_row/1,
           label: "session policy"
         ) do
      %Policy{} = policy -> {:ok, policy}
      nil -> :error
    end
  end

  @doc "A `SiteSessionPolicy` row (or `nil`, no row) as a `Policy`."
  @spec from_row(struct() | nil) :: Policy.t()
  def from_row(nil), do: off()

  def from_row(row) do
    %Policy{
      idle_seconds: minutes_to_seconds(row.idle_timeout_minutes),
      admin_idle_seconds: minutes_to_seconds(row.admin_idle_timeout_minutes),
      changed_at: row.policy_changed_at,
      revoked_at: row.sessions_revoked_at
    }
  end

  defp minutes_to_seconds(nil), do: nil
  defp minutes_to_seconds(minutes), do: minutes * 60

  @doc """
  The timeout, in seconds, for an account of `tier` on a site with `policy`;
  `nil` when none applies. An admin gets the shorter of the two that are set.
  """
  @spec timeout_seconds(Policy.t(), atom()) :: pos_integer() | nil
  def timeout_seconds(%Policy{idle_seconds: idle, admin_idle_seconds: admin}, :admin) do
    case Enum.reject([idle, admin], &is_nil/1) do
      [] -> nil
      set -> Enum.min(set)
    end
  end

  def timeout_seconds(%Policy{idle_seconds: idle}, _tier), do: idle

  @doc """
  Whether the tier changes the answer — the only case in which a check has to
  resolve it.
  """
  @spec tier_matters?(Policy.t()) :: boolean()
  def tier_matters?(policy), do: timeout_seconds(policy, :admin) != timeout_seconds(policy, :none)

  @doc """
  How stale `last_used_at` must be before a use writes it again: a tenth of the
  timeout, between 30 seconds and five minutes. `nil` (no timeout) is the
  session list's five minutes.
  """
  @spec touch_interval(pos_integer() | nil) :: pos_integer()
  def touch_interval(nil), do: Token.last_used_interval_minutes() * 60

  def touch_interval(timeout_seconds),
    do: timeout_seconds |> div(10) |> max(30) |> min(Token.last_used_interval_minutes() * 60)

  @doc "Whether the site's last \"sign out everyone\" can still catch a cookie."
  @spec watermark?(Policy.t()) :: boolean()
  def watermark?(%Policy{revoked_at: nil}), do: false

  def watermark?(%Policy{revoked_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at) < @watermark_horizon_seconds

  @doc "Milliseconds until a LiveView should look again, for `remaining` seconds."
  @spec timer_ms(integer()) :: pos_integer()
  def timer_ms(remaining), do: (max(remaining, 0) + @timer_slack_seconds) * 1000

  @doc """
  Check the session (or remember-me cookie) whose token is `jti` on the site
  `org_id`, and act on the verdict: sign it out when it is idle or predates the
  site's last "sign out everyone", note the use when it is active.

  Options:

    * `:policy` — the site's policy (default: `policy/1`);
    * `:tier` — a function returning the account's tier on the site, of no
      arguments or of the token row; called only when the tier changes the
      answer;
    * `:subject` — the account the row must belong to (`"user?id=…"`), from
      a verified token or the signed-in user; a row of another account is
      reported `:missing` and nothing is written to it. Every request path
      passes it;
    * `:touch?` — note the use when it is active (default `true`);
    * `:labels` — `%{browser:, platform:}` for the session list;
    * `:user` — the account, or a zero-arity function returning it, for the
      audit event;
    * `:surface` — `"http"`, `"live"` or `"remember_me"`, for the audit event;
    * `:request` — a `KilnCMS.Security.Recorder.request_context/1` map.

  Returns `{:active, %{timeout:, remaining:, idle:, jtis:}}` (`jtis`: the
  session's and its remember-me row's), `{:signed_out, why}`,
  or `:error` when the row could not be read or written (logged; the caller
  fails open).
  """
  @spec check(String.t(), Ash.UUID.t(), keyword()) :: verdict()
  def check(jti, org_id, opts \\ []) when is_binary(jti) and is_binary(org_id) do
    policy = Keyword.get_lazy(opts, :policy, fn -> policy(org_id) end)
    opts = Keyword.put(opts, :policy, policy)

    with {:ok, row} <- read(jti, policy) do
      act(verdict(row, policy, org_id, opts), row, policy, org_id, opts)
    end
  end

  @doc """
  The verdict on `row` without acting on it, for a caller that has already
  read it. `{:idle, timeout}` and `:stale` are what `check/3` acts on.
  """
  @spec verdict(Token.t() | nil, Policy.t(), Ash.UUID.t(), keyword()) ::
          {:active, map()}
          | {:idle, pos_integer()}
          | :stale
          | {:signed_out, atom()}
  def verdict(nil, _policy, _org_id, _opts), do: {:signed_out, :missing}

  def verdict(%Token{} = row, policy, org_id, opts) do
    # A row that is not the expected account's: a jti from a cookie names a
    # row, it does not prove whose. Nothing is done to it.
    if subject_matches?(row, opts),
      do: own_verdict(row, policy, org_id, opts),
      else: {:signed_out, :missing}
  end

  defp subject_matches?(row, opts) do
    case Keyword.get(opts, :subject) do
      nil -> true
      subject -> row.subject == subject
    end
  end

  defp own_verdict(%Token{purpose: "revocation"} = row, _policy, _org_id, _opts),
    do: {:signed_out, revoked_reason(row)}

  defp own_verdict(%Token{org_id: row_org}, _policy, org_id, _opts)
       when is_binary(row_org) and row_org != org_id,
       do: {:signed_out, :foreign}

  defp own_verdict(%Token{} = row, policy, _org_id, opts) do
    timeout = timeout_for(policy, opts, row)
    idle = row.idle_seconds

    cond do
      stale?(row, policy) -> :stale
      is_integer(timeout) and is_integer(idle) and idle >= timeout -> {:idle, timeout}
      true -> {:active, active_state(row, timeout, idle)}
    end
  end

  @doc "Why a revoked row was revoked, as `check/3` reports it."
  @spec revoked_reason(Token.t() | nil) :: :idle | :admin_sign_out_all | :revoked
  def revoked_reason(%Token{revoked_reason: reason}) do
    cond do
      reason == Token.idle_reason() -> :idle
      reason == Token.sign_out_all_reason() -> :admin_sign_out_all
      true -> :revoked
    end
  end

  def revoked_reason(_row), do: :revoked

  @doc """
  Read one token row by jti, with its idle time measured from no earlier than
  the policy's `changed_at`. `{:ok, nil}` when there is none.
  """
  @spec read(String.t(), Policy.t()) :: {:ok, Token.t() | nil} | :error
  def read(jti, %Policy{changed_at: floor}) do
    # authorize?: false — system bookkeeping keyed by a jti read from the signed
    # session; `:session_activity` forbids every caller by name.
    case Accounts.get_session_activity(jti,
           authorize?: false,
           not_found_error?: false,
           load: [idle_seconds: %{floor: floor}]
         ) do
      {:ok, row} ->
        {:ok, row}

      {:error, error} ->
        Logger.warning("Session activity could not be read: #{inspect(error)}")
        :error
    end
  rescue
    error ->
      Logger.warning("Session activity could not be read: #{Exception.message(error)}")
      :error
  end

  # --- acting on a verdict -----------------------------------------------------

  defp act({:active, state}, row, _policy, org_id, opts) do
    if Keyword.get(opts, :touch?, true) and due?(row, state.timeout) do
      touch(row, org_id, state.timeout, Keyword.get(opts, :labels, %{}))
    end

    {:active, state}
  end

  defp act({:idle, timeout}, row, policy, org_id, opts) do
    case expire(row, timeout, policy.changed_at, org_id, opts) do
      {:ok, revoked} ->
        if row.jti in revoked do
          record_idle(row, timeout, org_id, opts)
          SessionEviction.evict_session(row.jti, :idle)
          {:signed_out, :idle}
        else
          # Another tab touched the row (or another request already expired
          # it) between the read and the write; look again rather than guess.
          reread(row.jti, policy, org_id, opts)
        end

      :error ->
        :error
    end
  end

  defp act(:stale, row, policy, org_id, opts) do
    case revoke_stale(row, policy.revoked_at, opts) do
      {:ok, revoked} ->
        if row.jti in revoked do
          SessionEviction.evict_session(row.jti, :admin_sign_out_all)
          {:signed_out, :admin_sign_out_all}
        else
          # Bound to a site, or revoked, since the read: look again.
          reread(row.jti, policy, org_id, opts)
        end

      :error ->
        :error
    end
  end

  defp act({:signed_out, _why} = verdict, _row, _policy, _org_id, _opts), do: verdict

  defp reread(jti, policy, org_id, opts) do
    case read(jti, policy) do
      {:ok, row} ->
        case verdict(row, policy, org_id, opts) do
          {:active, _state} = active -> active
          {:signed_out, _why} = out -> out
          # Still idle by the read, yet the UPDATE matched nothing: fail open
          # for this request rather than loop.
          _other -> :error
        end

      :error ->
        :error
    end
  end

  defp active_state(row, timeout, idle) do
    %{
      timeout: timeout,
      remaining: remaining(timeout, idle),
      idle: idle,
      jtis: [row.jti | List.wrap(row.remember_me_jti)]
    }
  end

  defp timeout_for(policy, opts, row) do
    if tier_matters?(policy),
      do: timeout_seconds(policy, tier(Keyword.get(opts, :tier, fn -> :none end), row)),
      else: timeout_seconds(policy, :none)
  end

  defp tier(fun, row) when is_function(fun, 1), do: fun.(row)
  defp tier(fun, _row) when is_function(fun, 0), do: fun.()

  # Only a row bound to no site: every row bound to this one was revoked by the
  # sign-out itself, except the admin's own browser it was asked to keep.
  defp stale?(
         %Token{org_id: nil, created_at: created_at},
         %Policy{revoked_at: %DateTime{} = at} = policy
       ),
       do: watermark?(policy) and DateTime.compare(created_at, at) == :lt

  defp stale?(_row, _policy), do: false

  defp remaining(nil, _idle), do: nil
  defp remaining(timeout, idle) when is_integer(idle), do: timeout - idle
  defp remaining(timeout, _idle), do: timeout

  defp due?(%Token{idle_seconds: idle}, timeout) when is_integer(idle),
    do: idle >= touch_interval(timeout)

  defp due?(_row, _timeout), do: true

  @doc """
  Note that the session `jti` (and its remember-me row) was used on the site
  `org_id`, at most once per `touch_interval/1` of `timeout`. Best-effort.
  """
  @spec touch(Token.t(), Ash.UUID.t(), pos_integer() | nil, map()) :: :ok
  def touch(%Token{} = row, org_id, timeout, labels) do
    KilnCMS.Accounts.Sessions.record_use(
      [row.jti | List.wrap(row.remember_me_jti)],
      labels,
      org_id: org_id,
      interval_seconds: touch_interval(timeout)
    )
  end

  # The session row and its remember-me row, in one statement whose WHERE
  # repeats the verdict. Returns the jtis it revoked.
  defp expire(row, timeout, floor, org_id, opts) do
    jtis = [row.jti | List.wrap(row.remember_me_jti)]

    # authorize?: false — system bookkeeping on the session's own rows, keyed by
    # the jti read from the signed session; the action forbids every caller.
    case Accounts.expire_idle_sessions(
           Ash.Query.filter(Token, jti in ^jtis),
           %{
             timeout_seconds: timeout,
             floor: floor,
             subject: Keyword.get(opts, :subject) || row.subject,
             org_id: org_id
           },
           authorize?: false,
           bulk_options: [strategy: :atomic, return_records?: true, return_errors?: true]
         ) do
      %Ash.BulkResult{status: :success, records: records} ->
        {:ok, Enum.map(records || [], & &1.jti)}

      %Ash.BulkResult{errors: errors} ->
        Logger.warning("Could not expire an idle session: #{inspect(errors)}")
        :error
    end
  end

  defp revoke_stale(row, before, opts) do
    jtis = [row.jti | List.wrap(row.remember_me_jti)]

    # authorize?: false — system bookkeeping on the session's own rows, keyed by
    # the jti read from the signed session; the action forbids every caller.
    case Accounts.revoke_stale_sessions(
           Ash.Query.filter(Token, jti in ^jtis),
           %{before: before, subject: Keyword.get(opts, :subject) || row.subject},
           authorize?: false,
           bulk_options: [strategy: :atomic, return_records?: true, return_errors?: true]
         ) do
      %Ash.BulkResult{status: :success, records: records} ->
        {:ok, Enum.map(records || [], & &1.jti)}

      %Ash.BulkResult{errors: errors} ->
        Logger.warning(
          "Could not revoke a session older than sign-out-everyone: #{inspect(errors)}"
        )

        :error
    end
  end

  defp record_idle(row, timeout, org_id, opts) do
    # Which of the two timeouts applied: the administrators' own, or everyone's.
    tier =
      if timeout_seconds(Keyword.fetch!(opts, :policy), :none) == timeout,
        do: "member",
        else: "admin"

    Recorder.record_after_commit(:session_idle_expired,
      tenant: org_id,
      user: user_fun(row, opts),
      target_type: "session",
      metadata: %{
        "timeout_minutes" => Integer.to_string(div(timeout, 60)),
        "tier" => tier,
        "surface" => Keyword.get(opts, :surface, "http")
      },
      request: Keyword.get(opts, :request)
    )
  end

  defp user_fun(row, opts) do
    case Keyword.get(opts, :user) do
      fun when is_function(fun, 0) -> fun
      %{} = user -> user
      nil -> fn -> user_for(row) end
    end
  end

  @doc "The account a token row belongs to, or `nil`."
  @spec user_for(Token.t()) :: struct() | nil
  def user_for(%Token{subject: subject}) do
    case AshAuthentication.subject_to_user(subject, KilnCMS.Accounts.User, []) do
      {:ok, user} -> user
      _missing -> nil
    end
  end
end
