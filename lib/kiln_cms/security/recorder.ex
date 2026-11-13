defmodule KilnCMS.Security.Recorder do
  @moduledoc """
  Writes security audit events (#2241) and builds the request context they
  carry. The one place an emit site goes through; it fills the `actor_*`,
  `ip` and `user_agent` columns so no site hand-assembles them.

  ## Request context travels explicitly

  `request_context/1` turns a `Plug.Conn`, a LiveView socket (during mount) or
  a socket `connect_info` map into `%{ip: String.t() | nil, user_agent:
  String.t() | nil}`. The caller hands it to the action under the Ash context
  key `context_key/0` (see `context/1`) or to `record/2` as `:request`. There
  is no process dictionary: an action that runs in another process simply has
  no request context, and its event carries a `nil` ip.

  The ip is the one `KilnCMSWeb.Plugs.ClientIp` resolved (`conn.remote_ip`
  after the plug ran; `ClientIp.resolve/2` for a socket, the same rule), never
  the raw peer behind a proxy.

  ## Three ways to write

    * `record/2` - synchronous, returns the result. For a credential-changing
      action's `after_action` hook, so the event commits or rolls back with the
      change (like `MembershipEvent`). An `{:error, _}` returned from the hook
      rolls the change back.
    * `record_after_commit/2` - best-effort via `KilnCMS.AfterCommit`. Never
      raises into the caller; a failure is logged and counted on the
      `[:kiln_cms, :security, :event_failed]` telemetry event.
    * `record_sampled/2` - best-effort, for `:sign_in_failed`,
      `:admin_access_refused` (#2248) and `:sign_in_unlock_refused` (#2250),
      which anyone can trigger: a per-tenant,
      per-IP cap (`KilnCMS.Accounts.ThrottleStore`) keeps a flood from filling
      the log. Excess is dropped and counted on
      `[:kiln_cms, :security, :event_sampled_out]`. `:sign_in_locked` is never
      sampled away. `ThrottleStore.hit/5` refuses to run inside a transaction,
      so call this from outside one (a read action's hook, `after_transaction`).

  ## Options (all three)

    * `:tenant` - the org id. **Required** unless `:scope` is `:instance`:
      with none, the event is not recorded and `:skipped` is returned (a
      request to an unknown host has no org to attribute it to).
    * `:scope` - `:site` (default) or `:instance` (#2541). An instance event
      is about the installation, not a site: it goes to
      `KilnCMS.Security.InstanceEvent`, which only platform admins can read,
      takes no tenant (one given is ignored) and raises no alert. Only
      `record/2` and `record_after_commit/2` take it.
    * `:user` - the person who acted, a `KilnCMS.Accounts.User`, or `nil`.
      `actor_id` and `actor_label` (the email) are filled only for a known
      user; an unknown-account failure stores neither, so the log is not an
      enumeration oracle. May also be a zero-arity function returning either:
      it is called at most once, only when the event is actually written, so
      `record_sampled/2` does not pay for the lookup of an event it drops.
    * `:target_type`, `:target_id`, `:metadata` - see `KilnCMS.Security.Event`.
    * `:request` - a `request_context/1` map.
    * `:erasing_user_id` - the user an erasure is running for. An event whose
      acting user is that user (or is already anonymized) is `:skipped`, so
      erasure never writes the identity it just scrubbed.
    * `:alert` - `{:threshold, window_index, count}`: this event is the one
      that brought its site's failed sign-ins to the alert threshold (#2245).
      Set by `record_sampled/2` itself; see "Security alerts" below.
    * `:alert_required` - `true` when the event's security alert must be
      claimed or the event not written at all
      (`KilnCMS.Security.Changes.RaiseAlert`), for a caller with a fallback
      of its own (`KilnCMS.Accounts.ApiKeyReuse`). Default `false`: a failed
      claim never fails the event.

  ## Security alerts

  Recording an event is what raises its alerts (#2245):
  `KilnCMS.Security.Changes.RaiseAlert` classifies it in the event's own
  transaction. A failed sign-in raises one only on the site's tally
  (`KilnCMS.Security.Alerts.charge_failed_sign_in/2`): `record_sampled/2`
  charges every `:sign_in_failed` to its site, and the first attempt on this
  node to see the window's count reach the threshold is recorded
  **unsampled** and flagged,
  so the alert has its event even when the address behind it has used up its
  sample. The tally is keyed on the site alone, never on an address or
  account an attacker chooses.
  """

  require Logger

  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Accounts.User
  alias KilnCMS.AfterCommit
  alias KilnCMS.Security
  alias KilnCMS.Security.Alerts
  alias KilnCMSWeb.Plugs.ClientIp

  @context_key :security_request
  @tenant_key :security_tenant
  @max_user_agent 512

  @default_sample_limit 5
  @default_sample_scale :timer.minutes(15)
  # One bucket per sampled type, so a flood of one cannot spend the other's.
  @sample_buckets %{
    sign_in_failed: "security_sign_in_failed",
    admin_access_refused: "security_admin_access_refused",
    sign_in_unlock_refused: "security_sign_in_unlock_refused"
  }

  @typedoc "The request facts an event records."
  @type request :: %{ip: String.t() | nil, user_agent: String.t() | nil}

  @doc "The Ash context key the request context travels under."
  @spec context_key() :: :security_request
  def context_key, do: @context_key

  @doc """
  The Ash context key an org id travels under, for an action on a global
  resource (a user, a passkey) that has no tenant of its own. `Changes.Record`
  falls back to it, so an emit site on such an action still knows which org's
  log the event belongs to.
  """
  @spec tenant_key() :: :security_tenant
  def tenant_key, do: @tenant_key

  @doc """
  An Ash `context:` map carrying the request context for `source` (anything
  `request_context/1` takes), ready to pass to an action.
  """
  @spec context(Plug.Conn.t() | Phoenix.LiveView.Socket.t() | map()) :: %{
          security_request: request()
        }
  def context(source), do: %{@context_key => request_context(source)}

  @doc """
  The request context of a `Plug.Conn`, a LiveView socket (only readable
  during mount) or a socket `connect_info` map.
  """
  @spec request_context(Plug.Conn.t() | Phoenix.LiveView.Socket.t() | map()) :: request()
  def request_context(%Plug.Conn{} = conn) do
    %{
      ip: format_ip(conn.remote_ip),
      user_agent: conn |> Plug.Conn.get_req_header("user-agent") |> List.first() |> clean_ua()
    }
  end

  def request_context(%Phoenix.LiveView.Socket{} = socket) do
    # `connect_info` is only readable during mount, and only for keys the
    # endpoint declares; elsewhere the context is empty rather than an error.
    if Phoenix.LiveView.connected?(socket) do
      %{
        x_headers: connect_info(socket, :x_headers),
        peer_data: connect_info(socket, :peer_data),
        user_agent: connect_info(socket, :user_agent)
      }
      |> request_context()
    else
      %{ip: nil, user_agent: nil}
    end
  end

  def request_context(%{} = connect_info) do
    peer =
      case Map.get(connect_info, :peer_data) do
        %{address: address} -> address
        _none -> nil
      end

    ip = (Map.get(connect_info, :x_headers) || []) |> ClientIp.resolve(peer) |> format_ip()
    %{ip: ip, user_agent: clean_ua(Map.get(connect_info, :user_agent))}
  end

  defp connect_info(socket, key) do
    Phoenix.LiveView.get_connect_info(socket, key)
  rescue
    # Not mounting, or the endpoint does not declare the key.
    _not_available -> nil
  end

  defp format_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> nil
      charlist -> to_string(charlist)
    end
  end

  defp format_ip(_), do: nil

  defp clean_ua(ua) when is_binary(ua) do
    case ua |> String.slice(0, @max_user_agent) |> String.trim() do
      "" -> nil
      ua -> ua
    end
  end

  defp clean_ua(_), do: nil

  @doc """
  Record `type` now, in the caller's transaction. Returns `{:ok, event}`,
  `{:error, error}`, or `:skipped` (no tenant, or the acting user is being
  erased). See the moduledoc for `opts`.
  """
  @spec record(atom(), keyword()) ::
          {:ok, Security.Event.t() | Security.InstanceEvent.t()} | {:error, term()} | :skipped
  def record(type, opts) when is_atom(type) do
    case attrs(type, opts) do
      :skipped ->
        :skipped

      attrs ->
        if instance?(opts) do
          Security.record_instance_event(attrs, actor: Security.system())
        else
          Security.record(attrs,
            actor: Security.system(),
            tenant: Keyword.fetch!(opts, :tenant),
            context: alert_context(opts)
          )
        end
    end
  end

  # Anything but the two scopes raises: a skipped event reads as success to
  # the caller, so a typo would lose the audit silently.
  defp instance?(opts) do
    case Keyword.get(opts, :scope, :site) do
      :instance -> true
      :site -> false
      other -> raise ArgumentError, "scope must be :site or :instance, got: #{inspect(other)}"
    end
  end

  # What `Changes.RaiseAlert` reads from the recording changeset.
  defp alert_context(opts) do
    [
      security_alert: opts[:alert],
      security_alert_required: if(opts[:alert_required] == true, do: true)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  Record `type` once the surrounding transaction commits, never raising into
  the caller. Returns `:ok` (queued or written, or failed and reported) or
  `:skipped`.
  """
  @spec record_after_commit(atom(), keyword()) :: :ok | :skipped
  def record_after_commit(type, opts) when is_atom(type) do
    run_after_commit(type, opts, fn -> record(type, opts) end)
  end

  @doc """
  Best-effort record with a per-IP cap for `:sign_in_failed`,
  `:admin_access_refused` and `:sign_in_unlock_refused`. Every other type (`:sign_in_locked` in particular)
  is recorded as `record_after_commit/2` does, never sampled away.

  Extra options: `:limit` (events per window per IP, default
  #{@default_sample_limit}), `:scale` (window in ms, default 15 minutes) and
  `:sample_key` (what the cap counts per, instead of the request's ip — the
  admin allowlist passes an IPv6 client's `/64`, which one client can rotate
  through). Returns `:ok` (recorded or dropped) or `:skipped`.
  """
  @spec record_sampled(atom(), keyword()) :: :ok | :skipped
  def record_sampled(type, opts) when is_map_key(@sample_buckets, type) do
    if instance?(opts),
      do: raise(ArgumentError, "a sampled event type is never an instance event")

    run_after_commit(type, opts, fn -> record_if_admitted(type, opts) end)
  end

  def record_sampled(type, opts), do: record_after_commit(type, opts)

  defp run_after_commit(type, opts, fun) do
    # A lazy user is not resolved just to ask whether the event is skipped.
    if attrs(type, eager(opts)) == :skipped do
      :skipped
    else
      AfterCommit.run(fn -> best_effort(type, fun) end)
    end
  end

  defp eager(opts) do
    if is_function(Keyword.get(opts, :user), 0), do: Keyword.put(opts, :user, nil), else: opts
  end

  # A failed sign-in is charged to its site's alert tally first (#2245). The
  # attempt that reaches the threshold is recorded whatever the sample says,
  # flagged as the alert's event; every other one is sampled as before.
  defp record_if_admitted(:sign_in_failed = type, opts) do
    case Alerts.charge_failed_sign_in(Keyword.fetch!(opts, :tenant)) do
      {:threshold, _window_index, _count} = alert ->
        record(type, Keyword.put(opts, :alert, alert))

      _counted_or_off ->
        sample(type, opts)
    end
  end

  defp record_if_admitted(type, opts), do: sample(type, opts)

  defp sample(type, opts) do
    if admit?(type, opts) do
      record(type, opts)
    else
      :telemetry.execute([:kiln_cms, :security, :event_sampled_out], %{count: 1}, %{type: type})

      :ok
    end
  end

  defp admit?(type, opts) do
    key = Keyword.get(opts, :sample_key) || get_in(opts, [:request, :ip]) || "unknown"
    limit = Keyword.get(opts, :limit, @default_sample_limit)
    scale = Keyword.get(opts, :scale, @default_sample_scale)

    match?(
      {:allow, _},
      ThrottleStore.hit(
        Map.fetch!(@sample_buckets, type),
        "#{Keyword.fetch!(opts, :tenant)}:#{key}",
        scale,
        limit
      )
    )
  end

  defp best_effort(type, fun) do
    case fun.() do
      {:error, error} -> failed(type, error)
      _ok_or_skipped -> :ok
    end
  rescue
    # The audit write is secondary to the action it reports on: it must never
    # fail that action. The failure is logged and counted instead.
    error -> failed(type, error)
  catch
    :exit, reason -> failed(type, reason)
  end

  defp failed(type, error) do
    Logger.error("security event #{type} not recorded: #{inspect(error)}")
    :telemetry.execute([:kiln_cms, :security, :event_failed], %{count: 1}, %{type: type})
    :ok
  end

  # The create attributes, or `:skipped`.
  defp attrs(type, opts) do
    user =
      case Keyword.get(opts, :user) do
        fun when is_function(fun, 0) -> fun.()
        user -> user
      end

    cond do
      !instance?(opts) and !is_binary(Keyword.get(opts, :tenant)) -> :skipped
      erased?(user, Keyword.get(opts, :erasing_user_id)) -> :skipped
      true -> build(type, user, opts)
    end
  end

  defp erased?(%{id: id}, erasing) when not is_nil(erasing) and id == erasing, do: true
  defp erased?(%{anonymized_at: %DateTime{}}, _erasing), do: true
  defp erased?(_user, _erasing), do: false

  defp build(type, user, opts) do
    request = Keyword.get(opts, :request) || %{}

    %{
      type: type,
      actor_id: known_id(user),
      actor_label: known_label(user),
      target_type: Keyword.get(opts, :target_type),
      target_id: Keyword.get(opts, :target_id),
      ip: request[:ip],
      user_agent: request[:user_agent],
      metadata: Keyword.get(opts, :metadata) || %{}
    }
  end

  defp known_id(%User{id: id}), do: id
  defp known_id(_), do: nil
  defp known_label(%User{email: email}) when not is_nil(email), do: to_string(email)
  defp known_label(_), do: nil
end
