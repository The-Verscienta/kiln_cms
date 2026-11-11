defmodule KilnCMS.Challenge.Gate do
  @moduledoc """
  Decides whether a password sign-in or a registration needs a
  human-verification challenge, and whether the one it carries passes (#2249).

  Called from the actions — `KilnCMS.Accounts.Preparations.ThrottleSignIn` and
  `KilnCMS.Accounts.Changes.RequireRegistrationChallenge` — so every door is
  covered by one check: the sign-in LiveView, the no-JavaScript form POST and
  `POST /api/auth/sign_in` (when the operator turned `api_sign_in` on).

  ## Spend a free attempt, never the budget

  Each axis has a small allowance of attempts that need no challenge, and an
  attempt spends one with a single atomic increment-and-compare
  (`KilnCMS.Accounts.ThrottleStore.hit/5`) — so a simultaneous burst at the
  start of a window cannot all read "under the threshold" and skip the
  challenge together. Spending an allowance only decides whether a challenge is
  asked for. A sign-in refused for want of one never reaches
  `AccountThrottle.consume/1`: it costs the account's budget nothing and pays
  no bcrypt. Otherwise an attacker who never solves a challenge could still
  spend a victim's sign-in budget, and the challenge would have become the
  lockout it exists to replace. `consume/1` stays the only thing that admits.

  ## When a sign-in needs one

  `:adaptive` asks for a challenge once either allowance is spent
  (`KilnCMS.Challenge.threshold/1`):

    * **account** — `account_threshold` attempts on the *submitted* address in
      the account budget's window, cleared by any completed sign-in
      (`AccountThrottle.forgive/1`). Keyed on what was typed, never on a
      resolved account, so an address with no account is asked exactly when one
      with an account would be: the challenge is no oracle for which addresses
      exist.
    * **client address** — `ip_threshold` attempts from the caller's address,
      read from the request context every door attaches
      (`KilnCMS.Security.AuthEvents`). A sign-in whose password was right hands
      its unit back (`record_sign_in_success/1`), so in effect it counts the
      address's failures, and an office behind one address is not challenged
      for its own successful sign-ins.

  ## Failing open, and where that stops

  A refusal the provider gave is final. Only "the provider could not be
  asked" may admit an attempt, and only within a bound:

    * sign-in: open until the account's own budget (`AccountThrottle`, 20 a
      window) refuses, which happens anyway after this; and closed once the
      client address has failed `ip_closed_after` times (20 by default) in the
      window — an attacker cannot ride an outage past either.
    * registration: open, bounded by the per-address `:register` bucket
      `ThrottleRegistration` has already applied.

  A missing token is a refusal — unless this node has just seen the provider
  fail (`KilnCMS.Challenge.outage?/0`). Then the widget most likely could not
  load at all, and the attempt gets the same bounded treatment as a token the
  provider could not check; anything else would refuse the legitimate visitor
  with nothing to submit while admitting an attacker who submits junk.

  ## Public forms

  `form/3` decides a submission to a form that asks for a challenge
  (`KilnCMS.Challenge.form_required?/2`). A form is not an account: nothing is
  locked out and nothing is spent, so the question is only what to do with
  the submission. One rule for the browser route and the JSON API:

    * **passed** — accepted as `:passed`.
    * **no token** — *held*: stored, but scored as spam, so nobody is mailed,
      no webhook fires and no experiment counts it. A visitor whose widget
      could not load still reaches the inbox, and a script that never ran the
      widget gets nowhere. Also during an outage: a missing token is never
      admitted on the provider's say-so.
    * **the provider could not answer** — held too (`:unavailable`). The data
      is kept for review rather than refused, but an outage — which a caller
      can provoke with a burst of junk — never opens a way past the check.
    * **solved on another host** — held (`:wrong_host`), and logged at most
      once a minute naming the host the provider reported. Almost always a
      headless site the operator has not listed in `CHALLENGE_HOSTNAMES`, so
      it is kept rather than refused. The host the request named plays no part
      (`KilnCMS.Challenge.hostname_allowed?/1`).
    * **any other refusal** (invalid, expired, malformed, a token for another
      action) — refused: the visitor gets the form back to try again.
  """

  require Logger

  alias KilnCMS.Accounts.AccountThrottle
  alias KilnCMS.Accounts.ThrottleStore
  alias KilnCMS.Challenge
  alias KilnCMS.Security.Recorder

  # Failed sign-ins per client address, for where an outage stops admitting.
  @sign_in_ip_bucket "challenge:signin_ip"
  # Sign-ins per client address that needed no challenge, reserved before the
  # password is checked and handed back when it succeeds.
  @free_ip_bucket "challenge:free_signin_ip"
  @register_ip_bucket "challenge:register_ip"

  # The failure counter is never a gate, so its limit only has to be out of
  # reach: `hit/5` admits up to it and the count is all that is read.
  @count_only 1_000_000_000

  @type verdict :: :ok | {:refuse, KilnCMS.Accounts.Errors.ChallengeRequired.reason()}

  @typedoc "What a form submission records about its check (`FormSubmission.challenge`)."
  @type form_outcome :: :passed | :missing | :wrong_host | :unavailable

  @type form_verdict :: :not_required | {:accept, form_outcome()} | {:refuse, :failed}

  @doc """
  The verdict for a submission to `form` carrying `token` (see "Public
  forms" above). `:not_required` when the form does not ask for a challenge
  now — the provider is never called. `opts`: `:remote_ip`.

  Call it only for a submission that is otherwise acceptable: a tripped
  honeypot or a field error must not spend the token or a provider call.
  """
  @spec form(map(), term(), keyword()) :: form_verdict()
  def form(form, token, opts \\ []) do
    config = Challenge.config()

    if Challenge.form_required?(config, form) do
      {result, hostname} =
        Challenge.verify_reporting(config, token, :form,
          hostname?: hostname_check(),
          remote_ip: Keyword.get(opts, :remote_ip)
        )

      verdict = form_verdict(result)
      if verdict == {:accept, :wrong_host}, do: wrong_host_logged(hostname)

      decided(verdict, :form, form_decision(verdict))
    else
      :not_required
    end
  end

  defp form_decision({:accept, outcome}), do: outcome
  defp form_decision({:refuse, :failed}), do: :failed

  defp form_verdict(:ok), do: {:accept, :passed}
  defp form_verdict({:error, :missing}), do: {:accept, :missing}
  defp form_verdict({:error, :hostname_mismatch}), do: {:accept, :wrong_host}
  defp form_verdict({:error, {:unavailable, _reason}}), do: {:accept, :unavailable}
  defp form_verdict({:error, _refusal}), do: {:refuse, :failed}

  defp wrong_host_logged(hostname) do
    allowed =
      try do
        match?(
          {:allow, _},
          ThrottleStore.Local.hit(:challenge_form_wrong_host_logged, :timer.minutes(1), 1)
        )
      rescue
        ArgumentError -> true
      end

    if allowed do
      Logger.warning(
        "A form submission's human-verification token was solved on " <>
          "#{inspect(hostname)}, which this deployment does not serve; it was held as spam. " <>
          "If that is your own site, add it to CHALLENGE_HOSTNAMES."
      )
    end
  end

  @doc """
  The verdict for a password sign-in on `identifier` carrying `token`, from
  the action's `context`.

  Each axis spends one of its free attempts with an atomic increment-and-compare
  (`AccountThrottle.spend_free_attempt/2`, and `ThrottleStore.hit/5` on the
  client address), so a simultaneous burst cannot all slip under a threshold
  together: at most the threshold's worth skip the challenge. Spending a free
  attempt only decides whether a challenge is asked for — the account's own
  budget is still charged only for an attempt the challenge admits.
  """
  @spec sign_in(map(), String.t() | nil, term()) :: verdict()
  def sign_in(context, identifier, token) do
    config = Challenge.config()

    if applies?(config, context) do
      ip = client_ip(context)

      account =
        identifier &&
          AccountThrottle.spend_free_attempt(identifier, Challenge.threshold(:account))

      address = ip && spend_free_ip(ip)

      if account == :spent or address == :spent,
        do: verify_sign_in(config, ip, token),
        else: decided(:ok, :sign_in, :not_required)
    else
      :ok
    end
  end

  defp verify_sign_in(config, ip, token) do
    ip_failures = if ip, do: ThrottleStore.peek(@sign_in_ip_bucket, ip, ip_window()), else: 0

    config
    |> Challenge.verify(token, :sign_in, verify_opts(ip))
    |> outage_aware()
    |> sign_in_verdict(ip_failures)
    |> decided(:sign_in)
  end

  defp spend_free_ip(ip) do
    case ThrottleStore.hit(@free_ip_bucket, ip, ip_window(), Challenge.threshold(:ip)) do
      {:allow, _count} -> :free
      {:deny, _retry_after} -> :spent
    end
  end

  # A missing token while this node has just seen the provider fail is the
  # provider being down — the widget could not load — and gets the same
  # bounded treatment as a token the provider could not check.
  defp outage_aware({:error, :missing} = missing) do
    if Challenge.outage?(), do: {:error, {:unavailable, :outage}}, else: missing
  end

  defp outage_aware(result), do: result

  @doc """
  Whether a sign-in from this context would be asked for a challenge on the
  client-address axis alone — for the sign-in page to show the widget before
  the first submit (`KilnCMSWeb.SignInLive`). Charges nothing.
  """
  @spec sign_in_preshow?(map()) :: boolean()
  def sign_in_preshow?(context) do
    config = Challenge.config()

    with true <- applies?(config, context),
         ip when is_binary(ip) <- client_ip(context) do
      ThrottleStore.peek(@free_ip_bucket, ip, ip_window()) >= Challenge.threshold(:ip)
    else
      _no -> false
    end
  end

  @doc """
  Counts one failed sign-in against the caller's client address. Called for a
  credential failure only (a wrong password or an unknown address), never for a
  challenge refusal or a throttle, and only while sign-in is `:adaptive`. It
  decides where a provider outage stops admitting unverified attempts.

  Never inside a transaction (`ThrottleStore.hit/5` raises there).
  """
  @spec record_sign_in_failure(map()) :: :ok
  def record_sign_in_failure(context) do
    with %Challenge.Config{sign_in: :adaptive} <- Challenge.config(),
         ip when is_binary(ip) <- client_ip(context) do
      ThrottleStore.hit(@sign_in_ip_bucket, ip, ip_window(), @count_only)
    end

    :ok
  end

  @doc """
  Hands back the client address's free attempt when the password turned out
  right, so the people behind one address are not challenged for their own
  successful sign-ins — only failures keep it spent.
  """
  @spec record_sign_in_success(map()) :: :ok
  def record_sign_in_success(context) do
    with %Challenge.Config{sign_in: :adaptive} <- Challenge.config(),
         ip when is_binary(ip) <- client_ip(context) do
      ThrottleStore.refund(@free_ip_bucket, ip, ip_window())
    end

    :ok
  end

  @doc """
  The verdict for a registration carrying `token`. Under `:adaptive` every
  registration from an address spends one of its free ones atomically, so a
  burst cannot all skip the challenge.
  """
  @spec registration(map(), term()) :: verdict()
  def registration(context, token) do
    config = Challenge.config()

    case config.registration do
      :off ->
        :ok

      mode ->
        ip = client_ip(context)

        if mode == :always or spend_free_registration(ip) == :spent,
          do: verify_registration(config, ip, token),
          else: decided(:ok, :register, :not_required)
    end
  end

  defp verify_registration(config, ip, token) do
    config
    |> Challenge.verify(token, :register, verify_opts(ip))
    |> outage_aware()
    |> registration_verdict()
    |> decided(:register)
  end

  defp spend_free_registration(nil), do: :free

  defp spend_free_registration(ip) do
    window = Challenge.threshold(:registration_window)

    case ThrottleStore.hit(@register_ip_bucket, ip, window, Challenge.threshold(:registration)) do
      {:allow, _count} -> :free
      {:deny, _retry_after} -> :spent
    end
  end

  @doc """
  Whether a registration from this context would be asked for a challenge
  before its first submit. Charges nothing.
  """
  @spec registration_preshow?(map()) :: boolean()
  def registration_preshow?(context) do
    case Challenge.config().registration do
      :always -> true
      :adaptive -> registrations(client_ip(context)) >= Challenge.threshold(:registration)
      :off -> false
    end
  end

  defp registrations(nil), do: 0

  defp registrations(ip),
    do: ThrottleStore.peek(@register_ip_bucket, ip, Challenge.threshold(:registration_window))

  # Off, or the headless door while the operator has not opted it in.
  defp applies?(%Challenge.Config{sign_in: :off}, _context), do: false

  defp applies?(%Challenge.Config{api_sign_in: api?}, context) do
    surface(context) != :api or api?
  end

  defp sign_in_verdict(:ok, _ip_failures), do: {:ok, :passed}
  defp sign_in_verdict({:error, :missing}, _ip_failures), do: {{:refuse, :required}, :missing}

  defp sign_in_verdict({:error, {:unavailable, reason}}, ip_failures) do
    if ip_failures >= Challenge.threshold(:ip_closed_after) do
      fail_closed_logged(reason)
      {{:refuse, :unavailable}, :fail_closed}
    else
      {:ok, :fail_open}
    end
  end

  defp sign_in_verdict({:error, _refusal}, _ip_failures), do: {{:refuse, :failed}, :failed}

  defp registration_verdict(:ok), do: {:ok, :passed}
  defp registration_verdict({:error, :missing}), do: {{:refuse, :required}, :missing}
  defp registration_verdict({:error, {:unavailable, _reason}}), do: {:ok, :fail_open}
  defp registration_verdict({:error, _refusal}), do: {{:refuse, :failed}, :failed}

  defp decided({verdict, decision}, action), do: decided(verdict, action, decision)

  defp decided(verdict, action, decision) do
    :telemetry.execute([:kiln_cms, :challenge, :decision], %{count: 1}, %{
      action: action,
      decision: decision
    })

    verdict
  end

  # Logged because it refuses people who might be legitimate: an outage at the
  # provider, from an address that has already failed many sign-ins. Once a
  # minute per node, so an outage is not also a log flood.
  defp fail_closed_logged(reason) do
    allowed =
      try do
        match?(
          {:allow, _},
          ThrottleStore.Local.hit(:challenge_fail_closed_logged, :timer.minutes(1), 1)
        )
      rescue
        ArgumentError -> true
      end

    if allowed do
      Logger.error(
        "Human verification is unavailable (#{reason}); refusing password sign-ins from " <>
          "client addresses past the failure threshold until the provider answers."
      )
    end
  end

  defp verify_opts(ip), do: [hostname?: hostname_check(), remote_ip: ip]

  # Only hosts this deployment serves, or the operator's own list — never the
  # host the request named, which the caller chooses (a POST's `Host` header,
  # a LiveView join URL). See `KilnCMS.Challenge.hostname_allowed?/1`.
  defp hostname_check do
    if Keyword.get(Application.get_env(:kiln_cms, Challenge, []), :verify_hostname, true),
      do: &Challenge.hostname_allowed?/1
  end

  defp surface(context), do: context |> challenge_context() |> Map.get(:surface, :browser)

  defp challenge_context(context) when is_map(context) do
    case Map.get(context, Challenge.context_key()) do
      %{} = challenge -> challenge
      _none -> %{}
    end
  end

  defp challenge_context(_context), do: %{}

  # The client address every door records for the audit log: the conn's
  # (behind trusted proxies, `Plugs.ClientIp`) or the socket handshake's.
  defp client_ip(context) when is_map(context) do
    case get_in(context, [Recorder.context_key(), :ip]) do
      ip when is_binary(ip) and ip != "" -> ip
      _none -> nil
    end
  end

  defp client_ip(_context), do: nil

  defp ip_window, do: Challenge.threshold(:ip_window)
end
