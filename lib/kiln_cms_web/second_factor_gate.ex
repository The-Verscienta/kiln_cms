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

  ## Only on the main host and console hosts

  The setup page is served on the main host (`PHX_HOST`, the passkeys' RP ID)
  and on console hosts, never on a tenant site host (owner decision on #2247,
  2026-11-13): a passkey cannot be registered there
  (`KilnCMS.Accounts.WebAuthn.ceremony_host?/1`, decision record 0011), and a
  site host is the origin a site administrator's injected code runs on
  (`docs/threat-model.md`, item 16), which must not reach a visiting member's
  factors. `setup_host?/1` is that rule. On a site host every door sends a held
  account to the main host's page instead (`setup_location/3`), with no
  `return_to`: a path on this site means nothing there. The page itself
  refuses to render on a site host (`setup_host/1`, the first hook after the
  site is known). An account in its grace period on a site host is not sent
  away at sign-in; the grace banner links to the main host's page.
  """
  use KilnCMSWeb, :verified_routes

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.TwoFactorRequirement
  alias KilnCMS.Security.AuthEvents
  alias KilnCMSWeb.Plugs.ConsoleHost
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
  Whether the setup page is served on `host`: the main host (the endpoint's
  `PHX_HOST`) or a console host (`KilnCMSWeb.Plugs.ConsoleHost`). A tenant
  site host, and a request with no host, is not.
  """
  @spec setup_host?(String.t() | nil) :: boolean()
  def setup_host?(host) when is_binary(host) do
    normalize(host) == main_host() or ConsoleHost.console_host_name?(host)
  end

  def setup_host?(_host), do: false

  @doc "The setup page on the main host, as an absolute URL."
  @spec main_setup_url() :: String.t()
  def main_setup_url do
    KilnCMSWeb.Endpoint.struct_url()
    |> Map.put(:path, ~p"/account/two-factor")
    |> URI.to_string()
  end

  @doc """
  Where an account on `host` sets up a second factor: `setup_path/2` on a
  setup host (`setup_host?/1`), the main host's page (`main_setup_url/0`)
  anywhere else, without `return_to` or the reminder.
  """
  @spec setup_location(String.t() | nil, String.t() | nil, keyword()) :: String.t()
  def setup_location(host, return_to, opts \\ []) do
    if setup_host?(host), do: setup_path(return_to, opts), else: main_setup_url()
  end

  @doc """
  `Phoenix.Controller.redirect/2` and `Phoenix.LiveView.redirect/2` options
  for a `setup_location/3`: a local path as `:to`, the main host's URL as
  `:external`.
  """
  @spec redirect_opts(String.t()) :: keyword()
  def redirect_opts("/" <> _ = path), do: [to: path]
  def redirect_opts(url) when is_binary(url), do: [external: url]

  @doc """
  The first hook after the site is known on the setup page's `live_session`
  (`KilnCMSWeb.LiveUserAuth`, `:second_factor_setup_host`): the setup page
  mounted on a host that is not a setup host is redirected to the main host's
  page before anything else runs, signed in or not, on the disconnected
  render (a `302`) and a live mount alike. Every other page passes.
  """
  @spec setup_host(LiveView.Socket.t()) :: {:cont | :halt, LiveView.Socket.t()}
  def setup_host(socket) do
    if exempt_view?(socket) and not setup_host?(socket_host(socket)),
      do: {:halt, LiveView.redirect(socket, external: main_setup_url())},
      else: {:cont, socket}
  end

  @doc """
  The setup page's address for a link drawn on `host`: the local path on a
  setup host, the main host's URL anywhere else.
  """
  @spec setup_href(String.t() | nil) :: String.t()
  def setup_href(host), do: setup_location(host, nil)

  @doc "The host a mounted LiveView answers for (vouched by `LiveUserAuth`), or `nil`."
  @spec socket_host(LiveView.Socket.t()) :: String.t() | nil
  def socket_host(%{host_uri: %URI{host: host}}) when is_binary(host), do: host
  def socket_host(_socket), do: nil

  defp main_host, do: normalize(KilnCMSWeb.Endpoint.struct_url().host || "")

  # Hostnames are case-insensitive and a rooted FQDN's trailing dot names the
  # same host, as `KilnCMSWeb.Tenant` normalizes them.
  defp normalize(host), do: host |> String.trim_trailing(".") |> String.downcase()

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

  @doc """
  Whether a **bearer** credential of `user` (a JWT, the collab socket's
  token) is refused on `org_id`: the account is held, or it is a passkey-only
  account past its deadline (`TwoFactorRequirement.step_up/3` answers
  `:passkey_only`). A bearer never passed a passkey — the headless sign-in
  cannot take one — so for such an account it is the password alone, which
  the site no longer accepts (owner decisions 2 and 3). Bearers are not bound
  to the site that issued them, so this is asked of every site they reach.
  An account with the authenticator app, or none required, passes.
  """
  #
  # `opts` go to `held?/3`: a caller holding an actor loaded long ago (a
  # socket) passes `[]` so a hold is confirmed against the account as it is.
  @spec bearer_refused?(Accounts.User.t() | nil, Ash.UUID.t() | nil, keyword()) :: boolean()
  def bearer_refused?(user, org_id, opts \\ [fresh?: true])

  def bearer_refused?(%Accounts.User{} = user, org_id, opts) when is_binary(org_id) do
    held?(user, org_id, opts) or
      TwoFactorRequirement.step_up(user, org_id) == :passkey_only
  end

  def bearer_refused?(_user, _org_id, _opts), do: false

  @doc """
  Whether the browser session `session` (a conn's, or the map a LiveView
  mounts with) of `user` owes the passkey step-up on `org_id`: a passkey-only
  account past its deadline whose current session token
  (`KilnCMSWeb.SignInMarker`) never passed a second factor. A session that
  signed in before the deadline with its password, or that a remember-me
  cookie restored, is password-only access; it goes through the passkey
  prompt (`KilnCMSWeb.Plugs.PasskeyStepUp`) before anything else.
  """
  @spec passkey_step_up_owed?(Accounts.User.t() | nil, Ash.UUID.t() | nil, Plug.Conn.t() | map()) ::
          boolean()
  def passkey_step_up_owed?(%Accounts.User{} = user, org_id, session) when is_binary(org_id) do
    TwoFactorRequirement.step_up(user, org_id) == :passkey_only and
      not session_verified?(session)
  end

  def passkey_step_up_owed?(_user, _org_id, _session), do: false

  @doc """
  Whether the session's current token passed a second factor at sign-in (a
  code, a passkey step-up, or a passkey sign-in). A stale or absent marker
  is not.
  """
  @spec session_verified?(Plug.Conn.t() | map()) :: boolean()
  def session_verified?(session) do
    case KilnCMSWeb.SignInMarker.read(session) do
      %{second_factor_at: %DateTime{}} -> true
      %{method: "passkey"} -> true
      _password_only -> false
    end
  end

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
  `destination` otherwise. On a site host the held account goes to the main
  host's page (`setup_location/3`), and one in its grace period goes on to
  `destination`: the main host would ask it to sign in again for a reminder.
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

        setup_location(conn.host, destination)

      {:grace, _deadline} ->
        if setup_host?(conn.host),
          do: setup_path(destination, reminder?: true),
          else: destination

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
  policy and, in grace, the deadline. A passkey-only account's password-only
  session (`passkey_step_up_owed?/3`) goes to the passkey prompt instead,
  from every page, the setup page included.
  """
  @spec attach(LiveView.Socket.t(), map()) :: {:cont | :halt, LiveView.Socket.t()}
  def attach(socket, session) do
    user = socket.assigns[:current_user]
    org_id = org_id(socket)

    cond do
      passkey_step_up_owed?(user, org_id, session) -> {:halt, step_up(socket)}
      exempt_view?(socket) or not is_binary(org_id) or is_nil(user) -> attach_exempt(socket)
      true -> attach_judged(socket, user, org_id)
    end
  end

  defp attach_exempt(socket),
    do: {:cont, Phoenix.Component.assign(socket, :second_factor_status, :not_required)}

  defp attach_judged(socket, user, org_id) do
    status = TwoFactorRequirement.status(user, org_id)
    socket = Phoenix.Component.assign(socket, :second_factor_status, status)

    cond do
      match?({:enforced, _}, status) -> {:halt, hold(socket)}
      LiveView.connected?(socket) -> {:cont, follow(socket, org_id, status)}
      true -> {:cont, socket}
    end
  end

  @doc """
  For an anonymous-tolerant page (`/membership`, plugin public pages): a held
  signed-in account is sent to the setup page; an anonymous visitor, or one
  not held, is left alone.
  """
  @spec screen(LiveView.Socket.t(), map()) :: {:cont | :halt, LiveView.Socket.t()}
  def screen(socket, session) do
    user = socket.assigns[:current_user]
    org_id = org_id(socket)

    cond do
      passkey_step_up_owed?(user, org_id, session) -> {:halt, step_up(socket)}
      held?(user, org_id, fresh?: true) -> {:halt, hold(socket)}
      true -> {:cont, socket}
    end
  end

  # The passkey prompt, through `:browser_auth`, which turns the session into
  # a pending sign-in (`KilnCMSWeb.Plugs.PasskeyStepUp`).
  defp step_up(socket), do: LiveView.redirect(socket, to: ~p"/sign-in/verify")

  defp exempt_view?(socket), do: socket.view == KilnCMSWeb.TwoFactorSetupLive

  defp hold(socket),
    do: LiveView.redirect(socket, redirect_opts(setup_location(socket_host(socket), nil)))

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
