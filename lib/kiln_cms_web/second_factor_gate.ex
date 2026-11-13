defmodule KilnCMSWeb.SecondFactorGate do
  @moduledoc """
  Holding a signed-in account that owes its site a second factor (#2247) until
  it sets one up: "after grace, redirect to enrolment before anything else".

  Whether an account is held is `KilnCMS.Accounts.TwoFactorRequirement.status/3`
  on the site the request or socket resolved to: `{:enforced, deadline}`
  holds it, anything else does not. Every door asks it of the resolved site,
  never of a site of the caller's choosing.

  Three places act on it:

    * **Sign-in** — `sign_in_destination/3`, shared by every way a browser
      session completes (`KilnCMSWeb.AuthController.establish_session/5`,
      which every strategy and both step-ups reach, and the passkey
      ceremony): a held account lands on `/account/two-factor` and the
      `second_factor_required` security event is recorded, once per
      sign-in; an account in its grace period lands there too, with
      `?reminder=1`, which offers "Not now".
    * **Browser requests** — `KilnCMSWeb.Plugs.SecondFactorGate` on
      `:browser`, for a session that was already signed in (a remember-me
      cookie, a session from before the deadline).
    * **LiveViews** — `attach/2`, from `KilnCMSWeb.LiveUserAuth` on every
      signed-in live session, on the disconnected render and the live mount
      alike, and `screen/1` on the anonymous-tolerant public ones. A mounted
      page also listens for its site's policy changing and, during the grace
      period, wakes at the deadline, so a page left open does not outlive
      either.

  `/account/two-factor` (`KilnCMSWeb.TwoFactorSetupLive`) is never held: it is
  where a held account goes.
  """
  use KilnCMSWeb, :verified_routes

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.Security.AuthEvents
  alias Phoenix.LiveView

  @key :kiln_second_factor

  # The longest a page sleeps before looking again while in grace. A grace
  # period can be 90 days; a timer that long would outlive a deploy anyway.
  @max_wait_ms :timer.hours(24)

  @doc "The setup page, sending the account on to `return_to` (a local path) afterwards."
  @spec setup_path(String.t() | nil, keyword()) :: String.t()
  def setup_path(return_to, opts \\ []) do
    query =
      [
        if(Keyword.get(opts, :reminder?, false), do: {"reminder", "1"}),
        if(is_binary(return_to) and KilnCMSWeb.SafeRedirect.safe_local_path?(return_to),
          do: {"return_to", return_to}
        )
      ]
      |> Enum.reject(&is_nil/1)

    case query do
      [] -> ~p"/account/two-factor"
      query -> ~p"/account/two-factor" <> "?" <> URI.encode_query(query)
    end
  end

  @doc """
  Whether `user` is held on `org_id`: their site requires a second factor of
  them and the grace period is over. `nil` (anonymous) and a site-less request
  never are.

  `user` may have been loaded before an enrolment in another tab; a held
  answer is confirmed against the account as it is now, so a page that
  outlived the enrolment does not bounce it.
  """
  @spec held?(Accounts.User.t() | nil, Ash.UUID.t() | nil, keyword()) :: boolean()
  def held?(user, org_id, opts \\ [])

  def held?(%Accounts.User{} = user, org_id, opts) when is_binary(org_id) do
    case TwoFactorRequirement.status(user, org_id, opts) do
      {:enforced, _deadline} -> confirmed_held?(user, org_id, opts)
      _not_held -> false
    end
  end

  def held?(_user, _org_id, _opts), do: false

  defp confirmed_held?(user, org_id, opts) do
    if Keyword.get(opts, :fresh?, false) do
      true
    else
      case reload(user) do
        %Accounts.User{} = fresh ->
          match?({:enforced, _}, TwoFactorRequirement.status(fresh, org_id, opts))

        # Deleted since: whatever loaded it is about to find out; holding it
        # here changes nothing.
        nil ->
          false
      end
    end
  end

  # The account the session or token already names, re-read as itself (the
  # `User` read policy admits self) to see whether it has enrolled since.
  defp reload(user) do
    case Accounts.get_user(user.id, actor: user, not_found_error?: false) do
      {:ok, fresh} -> fresh
      _error -> nil
    end
  end

  @doc """
  Where a browser sign-in of `user` on `conn` goes instead of `destination`:
  the setup page when the site holds them (recording `second_factor_required`
  once, here), the setup page with "Not now" during their grace period, and
  `destination` otherwise.
  """
  @spec sign_in_destination(Plug.Conn.t(), Accounts.User.t(), String.t()) :: String.t()
  def sign_in_destination(%Plug.Conn{} = conn, %Accounts.User{} = user, destination) do
    case TwoFactorRequirement.status(user, org_id(conn)) do
      {:enforced, _deadline} ->
        AuthEvents.second_factor_required(
          AuthEvents.context(conn),
          user,
          "browser",
          "not_enrolled"
        )

        setup_path(destination)

      {:grace, _deadline} ->
        setup_path(destination, reminder?: true)

      _not_held ->
        destination
    end
  end

  # --- LiveView ----------------------------------------------------------------

  @doc """
  Attach to a signed-in mount, after the session itself was judged
  (`KilnCMSWeb.IdleSession`). Assigns `:second_factor_status` and halts with
  a redirect to the setup page when the account is held, on the disconnected
  render and the live mount alike. On a live mount it also follows the site's
  policy and, in grace, the deadline.
  """
  @spec attach(LiveView.Socket.t(), map()) :: {:cont | :halt, LiveView.Socket.t()}
  def attach(socket, _session) do
    user = socket.assigns[:current_user]
    org_id = org_id(socket)

    if exempt_view?(socket) or not is_binary(org_id) or is_nil(user) do
      {:cont, Phoenix.Component.assign(socket, :second_factor_status, :not_required)}
    else
      status = TwoFactorRequirement.status(user, org_id)
      socket = Phoenix.Component.assign(socket, :second_factor_status, status)

      cond do
        match?({:enforced, _}, status) -> {:halt, hold(socket)}
        LiveView.connected?(socket) -> {:cont, follow(socket, org_id, status)}
        true -> {:cont, socket}
      end
    end
  end

  @doc """
  For an anonymous-tolerant page (`/membership`, plugin public pages): a held
  signed-in account is sent to the setup page; an anonymous visitor, or one
  not held, is left alone.
  """
  @spec screen(LiveView.Socket.t()) :: {:cont | :halt, LiveView.Socket.t()}
  def screen(socket) do
    if held?(socket.assigns[:current_user], org_id(socket), fresh?: true),
      do: {:halt, hold(socket)},
      else: {:cont, socket}
  end

  defp exempt_view?(socket), do: socket.view == KilnCMSWeb.TwoFactorSetupLive

  defp hold(socket), do: LiveView.redirect(socket, to: setup_path(nil))

  defp follow(socket, org_id, status) do
    Phoenix.PubSub.subscribe(KilnCMS.PubSub, TwoFactorRequirement.topic(org_id))

    socket
    |> LiveView.put_private(@key, %{org_id: org_id, timer: nil})
    |> arm(status)
    |> LiveView.attach_hook(:second_factor_gate, :handle_info, &handle_info/2)
  end

  defp handle_info({:second_factor_policy_changed, policy}, %{private: %{@key => _}} = socket),
    do: recheck(socket, policy: policy)

  defp handle_info(:second_factor_deadline, %{private: %{@key => _}} = socket),
    do: recheck(socket, [])

  defp handle_info(_message, socket), do: {:cont, socket}

  # The policy message reaches every LiveView of the site, hooked or not, and
  # is halted here only because this hook is what it was sent for.
  defp recheck(%{private: %{@key => state}} = socket, opts) do
    user = socket.assigns.current_user

    if held?(user, state.org_id, opts) do
      {:halt, hold(socket)}
    else
      status = TwoFactorRequirement.status(user, state.org_id, opts)

      {:halt,
       socket
       |> Phoenix.Component.assign(:second_factor_status, status)
       |> arm(status)}
    end
  end

  defp arm(%{private: %{@key => state}} = socket, status) do
    if state.timer, do: Process.cancel_timer(state.timer)

    timer =
      case status do
        {:grace, deadline} ->
          wait = deadline |> DateTime.diff(DateTime.utc_now(), :millisecond) |> max(0)
          Process.send_after(self(), :second_factor_deadline, min(wait, @max_wait_ms))

        _not_in_grace ->
          nil
      end

    LiveView.put_private(socket, @key, %{state | timer: timer})
  end

  defp org_id(%{assigns: %{current_org: %{id: id}}}) when is_binary(id), do: id
  defp org_id(_conn_or_socket), do: nil
end
