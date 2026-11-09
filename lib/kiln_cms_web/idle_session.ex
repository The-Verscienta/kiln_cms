defmodule KilnCMSWeb.IdleSession do
  @moduledoc """
  The idle timeout and "sign out everyone" (#2246) for a signed-in LiveView.

  Attached by `KilnCMSWeb.LiveUserAuth` to every signed-in mount, ahead of
  `KilnCMSWeb.SessionTracking`. On a connected mount it:

    * checks the session against the site's policy
      (`KilnCMS.Accounts.IdleTimeout.check/3`) and sends the page to sign-in
      when it is idle, predates the site's last "sign out everyone", is bound
      to another site, or is already revoked;
    * notes the use — on the first mount only, not on a rejoin (a socket
      reconnecting after a deploy or a network blip is not the person doing
      anything) — and on every event the page handles, at most once per
      `IdleTimeout.touch_interval/1`;
    * arms one timer for when the session would go idle. When it fires, the
      page re-reads the row without touching it: another tab may have kept the
      session awake (re-arm), signed it out (leave), or nobody did (expire and
      leave);
    * listens for the site's policy changing, so a timeout turned on after the
      page opened applies to it, and a "sign out everyone" reaches it.

  Timers, PubSub messages, the rejoin and the replies a hook sends on its own
  (`activity_event?/1`) are not activity: an open tab nobody touches goes idle
  like any other. A patch (`handle_params` after the first) is.

  Events handled by a LiveComponent (`phx-target={@myself}`) are not seen by
  the LiveView's `handle_event` hook, so they do not count as activity on
  their own. Every component page here also raises page-level events (form
  changes, navigation), and a person working in one keeps the session awake
  through those; a page driven purely by component events can idle out under
  the person using it.
  """
  use KilnCMSWeb, :verified_routes
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Accounts.IdleTimeout
  alias KilnCMS.Accounts.Sessions
  alias KilnCMS.Accounts.Token
  alias KilnCMS.Security.Recorder
  alias Phoenix.LiveView

  @key :kiln_idle

  # Client events a hook sends without the person doing anything.
  @automatic_events ~w(body_flushed push_state push_unsupported)

  # How long to wait before looking again when a check could not read the row.
  @retry_ms :timer.seconds(60)

  # A policy change reaches every open page of a site at once; spread their
  # re-reads over this window rather than in one burst.
  @jitter_ms 2_000

  @doc """
  Attach to a signed-in mount; `session` is the LiveView session. Returns
  `{:cont, socket}` or `{:halt, socket}` (redirected to sign-in).
  """
  @spec attach(LiveView.Socket.t(), map()) :: {:cont | :halt, LiveView.Socket.t()}
  def attach(socket, session) do
    jti = Token.peeked_jti(session["user_token"])
    org_id = org_id(socket)

    if is_binary(jti) and is_binary(org_id) and LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(KilnCMS.PubSub, IdleTimeout.topic(org_id))
      policy = IdleTimeout.policy(org_id)

      state = %{
        jti: jti,
        org_id: org_id,
        policy: policy,
        jtis: [jti],
        timer: nil,
        interval: IdleTimeout.touch_interval(nil),
        # `nil`: the next event writes (the database's own throttle still
        # applies). A mount that did not write — a rejoin, or a use inside the
        # interval — must not swallow the first events after it.
        touched_at: nil,
        params_seen?: false
      }

      opts =
        check_opts(socket, policy,
          touch?: not rejoin?(socket),
          labels: KilnCMSWeb.UserAgent.parse(user_agent(socket)),
          request: Recorder.request_context(socket)
        )

      case IdleTimeout.check(jti, org_id, opts) do
        {:signed_out, why} ->
          {:halt, leave(socket, why)}

        result ->
          {:cont,
           socket
           |> LiveView.put_private(@key, state)
           |> arm(result)
           |> LiveView.attach_hook(:idle_session_event, :handle_event, &handle_event/3)
           |> LiveView.attach_hook(:idle_session_params, :handle_params, &handle_params/3)
           |> LiveView.attach_hook(:idle_session_info, :handle_info, &handle_info/2)}
      end
    else
      {:cont, socket}
    end
  end

  @doc """
  Judge the signed-in user a mount was handed, connected or not, without
  noting a use (#2246): a session that is idle, predates the site's last "sign
  out everyone", is bound to another site or is revoked is treated as signed
  out — `:current_user` becomes `nil`, so a signed-in-only page redirects to
  sign-in and an anonymous-tolerant one renders anonymously.

  `KilnCMSWeb.LiveUserAuth` runs it once the mount's site is known. A row that
  cannot be read leaves the user as it was (fails open).
  """
  @spec screen(LiveView.Socket.t(), map()) :: LiveView.Socket.t()
  def screen(socket, session) do
    with %{} = user <- socket.assigns[:current_user],
         jti when is_binary(jti) <- Token.peeked_jti(session["user_token"]),
         org_id when is_binary(org_id) <- org_id(socket) do
      opts =
        check_opts(socket, IdleTimeout.policy(org_id),
          touch?: false,
          request: Recorder.request_context(socket)
        )

      case IdleTimeout.check(jti, org_id, Keyword.put(opts, :user, user)) do
        {:signed_out, _why} -> Phoenix.Component.assign(socket, :current_user, nil)
        _active_or_unreadable -> socket
      end
    else
      _anonymous_or_no_site -> socket
    end
  end

  @doc """
  Whether this connected mount is a rejoin — the socket reconnecting — rather
  than the page being opened. Only meaningful during mount.
  """
  @spec rejoin?(LiveView.Socket.t()) :: boolean()
  def rejoin?(socket) do
    case LiveView.get_connect_params(socket) do
      %{"_mounts" => mounts} when is_integer(mounts) -> mounts > 0
      _not_connected -> false
    end
  end

  # --- hooks -------------------------------------------------------------------

  # Every event a person sends is activity: note it, at most once per interval.
  # A few are the browser answering the server on its own, not the person.
  defp handle_event(event, _params, socket) do
    if activity_event?(event), do: {:cont, touch(socket)}, else: {:cont, socket}
  end

  @doc """
  Whether a client event counts as the person's activity. Not the replies a
  hook sends by itself: `body_flushed` (the rich-text editor answering a
  lock takeover's `flush_body`), and `push_state` / `push_unsupported` (the
  push hook reporting the browser's state when it mounts).
  """
  @spec activity_event?(String.t()) :: boolean()
  def activity_event?(event), do: event not in @automatic_events

  # A patch (`live_patch`, `push_patch`) is navigation, and navigation is
  # activity. The first call is the mount's own, already counted.
  defp handle_params(
         _params,
         _uri,
         %{private: %{@key => %{params_seen?: false} = state}} = socket
       ),
       do: {:cont, LiveView.put_private(socket, @key, %{state | params_seen?: true})}

  defp handle_params(_params, _uri, socket), do: {:cont, touch(socket)}

  defp handle_info({:kiln_idle_check, jti}, %{private: %{@key => %{jti: jti}}} = socket),
    do: recheck(socket)

  defp handle_info(:kiln_idle_policy_check, socket), do: recheck(socket)

  defp handle_info({:session_policy_changed, policy}, %{private: %{@key => state}} = socket) do
    Process.send_after(self(), :kiln_idle_policy_check, :rand.uniform(@jitter_ms))
    {:halt, LiveView.put_private(socket, @key, %{state | policy: policy})}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  # --- internals ---------------------------------------------------------------

  defp recheck(%{private: %{@key => state}} = socket) do
    opts = check_opts(socket, state.policy, touch?: false, request: request(socket))

    case IdleTimeout.check(state.jti, state.org_id, opts) do
      {:signed_out, why} -> {:halt, leave(socket, why)}
      result -> {:halt, arm(socket, result)}
    end
  end

  defp check_opts(socket, policy, opts) do
    [
      policy: policy,
      subject: AshAuthentication.user_to_subject(socket.assigns.current_user),
      tier: fn -> KilnCMSWeb.LiveUserAuth.effective_tier(socket) end,
      user: socket.assigns[:current_user],
      surface: "live"
    ] ++ opts
  end

  defp arm(%{private: %{@key => state}} = socket, result) do
    if state.timer, do: Process.cancel_timer(state.timer)

    state =
      case result do
        {:active, %{remaining: remaining, timeout: timeout} = active} ->
          timer =
            if is_integer(remaining),
              do:
                Process.send_after(
                  self(),
                  {:kiln_idle_check, state.jti},
                  IdleTimeout.timer_ms(remaining)
                )

          %{
            state
            | timer: timer,
              interval: IdleTimeout.touch_interval(timeout),
              jtis: Map.get(active, :jtis, state.jtis)
          }

        :error ->
          # Fail open for this tick, and look again.
          %{state | timer: Process.send_after(self(), {:kiln_idle_check, state.jti}, @retry_ms)}
      end

    LiveView.put_private(socket, @key, state)
  end

  defp touch(%{private: %{@key => state}} = socket) do
    now = System.monotonic_time(:millisecond)

    if is_nil(state.touched_at) or now - state.touched_at >= state.interval * 1000 do
      Sessions.record_use(state.jtis, %{},
        org_id: state.org_id,
        interval_seconds: state.interval
      )

      LiveView.put_private(socket, @key, %{state | touched_at: now})
    else
      socket
    end
  end

  defp touch(socket), do: socket

  defp leave(socket, why) do
    socket
    |> put_reason_flash(why)
    |> LiveView.redirect(to: ~p"/sign-in")
  end

  @doc "The flash a page shows on its way to sign-in, by why the session ended."
  @spec reason_message(atom()) :: String.t() | nil
  def reason_message(:idle), do: gettext("You were signed out after a period of inactivity.")

  def reason_message(:admin_sign_out_all),
    do: gettext("An administrator signed everyone out of this site. Sign in again to continue.")

  def reason_message(_other), do: nil

  defp put_reason_flash(socket, why) do
    case reason_message(why) do
      nil -> socket
      message -> LiveView.put_flash(socket, :info, message)
    end
  end

  defp request(socket) do
    case socket.assigns[:security_context] do
      %{} = context -> Map.get(context, Recorder.context_key())
      _none -> nil
    end
  end

  defp org_id(socket) do
    case socket.assigns[:current_org] do
      %{id: id} when is_binary(id) -> id
      _none -> nil
    end
  end

  defp user_agent(socket) do
    LiveView.get_connect_info(socket, :user_agent)
  rescue
    # Only readable during mount, and only when the endpoint declares it.
    _not_available -> nil
  end
end
