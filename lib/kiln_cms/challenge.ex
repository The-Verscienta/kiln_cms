defmodule KilnCMS.Challenge do
  @moduledoc """
  Adaptive human verification for password sign-in and registration, and
  opt-in verification on public forms (#2249).

  A challenge is asked for only when an attempt looks like part of a guessing
  run, so most people never see one. The provider is the operator's pick
  among the registered ones (`KilnCMS.Challenge.Registry`): Cloudflare
  Turnstile (`KilnCMS.Challenge.Providers.Turnstile`, recommended), Google
  reCAPTCHA v2 (`KilnCMS.Challenge.Providers.Recaptcha`), or one a plugin
  contributes (`Kiln.Challenge.Provider`). `KilnCMS.Challenge.Gate` makes that decision on the
  actions themselves; this module is the operator's configuration and the one
  place a token is verified.

  ## Operator-only, and deployment-wide

  Everything here is the operator's: the provider, its keys, and the modes.
  There is no per-site setting, and that is a security property rather than a
  missing feature. An account is global — one `User` signs in on every site it
  belongs to — so a site that could turn sign-in challenges off would be the
  door every *other* site's users are guessed through. Whether a challenge is
  needed is decided from the account's and the caller's own counters, never
  from the host that was dialled.

      config :kiln_cms, KilnCMS.Challenge,
        provider: "turnstile",            # CHALLENGE_PROVIDER: turnstile,
                                          # recaptcha or a plugin's id
        site_key: "0x4AAAA…",             # CHALLENGE_SITE_KEY
        secret_key: {:env, %{"var" => "CHALLENGE_SECRET_KEY"}},
                                          # or CHALLENGE_SECRET_KEY_FILE
        sign_in: :adaptive,               # :off | :adaptive
        registration: :adaptive,          # :off | :adaptive | :always
        api_sign_in: false,               # challenge POST /api/auth/sign_in too
        forms: true,                      # CHALLENGE_FORMS: let a form ask for
                                          # one (`KilnCMS.CMS.Form.challenge`)
        hostnames: [],                    # CHALLENGE_HOSTNAMES: extra hosts a
                                          # token may be solved on
        disabled: false                   # KILN_CHALLENGE_DISABLED

  The secret is read through `KilnCMS.Keys` (`fetch(:challenge_secret)`) only
  when a token is verified, never cached and never logged. Whether the feature
  is on depends on its *source* being configured, so a secret file that cannot
  be read makes verification unavailable (bounded fail-open) rather than
  switching challenges off.

  ## Public forms

  Forms are the one place a *site* chooses: each `KilnCMS.CMS.Form` carries
  `challenge: :off | :always` (`:off` by default), because a form that turns
  it off exposes only that site's own inbox. The operator still holds the
  ceiling — `forms: false` (`CHALLENGE_FORMS=false`), the kill switch or an
  unusable provider makes every form `:off` in effect (`form_required?/2`),
  and an admin cannot switch a form to `:always` while that is so
  (`KilnCMS.CMS.Validations.ChallengeAvailable`). What a form submission's
  answer does is `KilnCMS.Challenge.Gate.form/3`'s to decide.

  ## When nothing is required

  With no provider, an id no installed provider answers to, a provider that
  fails `Kiln.Challenge.Provider.conformance/1`, a missing site key or
  secret, or the kill switch on, **nothing is required anywhere**: no widget
  is drawn, the Content-Security-Policy is not widened, and every attempt is
  decided exactly as it was before this existed. A provider that is named but
  unusable is logged at most once a minute per node (and an unknown or
  non-conforming one at boot), so a typo is visible rather than silently
  turning the control off.

  ## Resolved once

  The named provider is resolved and checked once per node and value
  (`:persistent_term`), into a `Descriptor`. Request paths read only that:
  they never call a provider's callbacks, so a plugin's provider cannot slow
  or crash a page by what its `widget/0` does. Only `verify/2` runs per
  attempt, in a task under the deadline.

  ## What the core checks, whatever the provider

  A provider's pass reports where the token was solved
  (`t:Kiln.Challenge.Provider.claims/0`), and `verify/4` enforces it: a
  hostname that is missing or not this deployment's (`hostname_allowed?/1`)
  is `:hostname_mismatch`, and an action that differs from the one the
  widget was drawn for is `:action_mismatch`. A provider answering outside
  its contract is read conservatively: a refusal Kiln does not know
  (`:missing` and `:malformed` included, which only the core's own precheck
  may give) is `:invalid`, never "no token".

  ## Thresholds

  Operator config only, with these defaults:

    * `account_threshold: 3` — sign-in attempts on one submitted address in
      the account budget's window (`KilnCMS.Accounts.AccountThrottle`, 15 min);
    * `ip_threshold: 5` — failed sign-ins from one client address in
      `ip_window` (15 min);
    * `ip_closed_after` — failed sign-ins from one address past which a provider
      outage stops admitting unverified attempts; `ip_threshold * 4` (20) by
      default;
    * `registration_threshold: 2` — registrations from one address in
      `registration_window` (1 h);
    * `deadline: 3_000` — the whole verification, DNS included, in ms;
    * `outage_window: 60_000` — how long an "unavailable" answer makes a
      missing token count as the provider being down (`outage?/0`).
  """

  require Logger

  alias KilnCMS.Challenge.Registry
  alias KilnCMS.Challenge.Transport

  @context_key :kiln_challenge
  @outage_key {__MODULE__, :outage_until}
  @descriptor_key {__MODULE__, :descriptor}

  @provider_id ~r/\A[a-z][a-z0-9_]{0,31}\z/

  @refusals [:invalid, :expired, :hostname_mismatch, :action_mismatch]
  @unavailable [
    :timeout,
    :transport,
    :http_status,
    :malformed_response,
    :not_configured,
    :crashed
  ]

  @token_max_bytes 2048

  @default_deadline 3_000

  @type mode :: :off | :adaptive | :always
  @type surface :: :browser | :api
  @type action :: :sign_in | :register | :form

  defmodule Descriptor do
    @moduledoc """
    A provider as the core uses it: `Kiln.Challenge.Provider.describe/1`'s
    answer, checked once and memoised (see `KilnCMS.Challenge`). `fingerprint`
    is a short digest of what the browser is told (the widget data), part of a
    delivered page's ETag.
    """
    @enforce_keys [
      :id,
      :label,
      :module,
      :script_url,
      :global,
      :api,
      :render_options,
      :action_option,
      :onload_param,
      :response_field,
      :interactive,
      :csp,
      :fingerprint
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: String.t(),
            label: String.t(),
            module: module(),
            script_url: String.t(),
            global: String.t(),
            api: :explicit_render,
            render_options: map(),
            action_option: String.t() | nil,
            onload_param: String.t() | nil,
            response_field: String.t() | nil,
            interactive: boolean(),
            csp: Kiln.Challenge.Provider.csp_sources(),
            fingerprint: String.t()
          }
  end

  defmodule Config do
    @moduledoc """
    The resolved configuration: `provider` (the module) and `descriptor` are
    `nil` whenever nothing may be required (see `KilnCMS.Challenge`), and both
    modes are then `:off`.
    """
    @enforce_keys [
      :provider,
      :descriptor,
      :site_key,
      :sign_in,
      :registration,
      :api_sign_in,
      :forms
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            provider: module() | nil,
            descriptor: KilnCMS.Challenge.Descriptor.t() | nil,
            site_key: String.t() | nil,
            sign_in: :off | :adaptive,
            registration: :off | :adaptive | :always,
            api_sign_in: boolean(),
            forms: boolean()
          }
  end

  @doc """
  The configuration in effect now. Cheap enough to call per request: it reads
  application env, the memoised provider descriptor, and checks that a secret
  *source* is configured (a set variable or a file path) without reading the
  secret.
  """
  @spec config() :: Config.t()
  def config do
    opts = settings()

    case usable_provider(opts) do
      {:ok, descriptor, site_key} ->
        %Config{
          provider: descriptor.module,
          descriptor: descriptor,
          site_key: site_key,
          sign_in: mode(opts[:sign_in], [:off, :adaptive], :adaptive),
          registration: mode(opts[:registration], [:off, :adaptive, :always], :adaptive),
          api_sign_in: opts[:api_sign_in] == true,
          forms: opts[:forms] != false
        }

      :off ->
        off()
    end
  end

  @doc "Whether any surface can ask for a challenge right now."
  @spec enabled?(Config.t()) :: boolean()
  def enabled?(%Config{provider: nil}), do: false
  def enabled?(%Config{sign_in: :off, registration: :off}), do: false
  def enabled?(%Config{}), do: true

  @doc """
  What the browser needs to draw the widget for `action`, or `nil` when no
  challenge can be asked for there.
  """
  @spec widget(Config.t(), action()) :: map() | nil
  def widget(%Config{provider: nil}, _action), do: nil

  def widget(%Config{} = config, :form) do
    if forms_available?(config), do: widget_map(config, :form)
  end

  def widget(%Config{} = config, action) when action in [:sign_in, :register] do
    if mode_for(config, action) != :off, do: widget_map(config, action)
  end

  # `action` is what the widget is drawn for and what verification expects;
  # `action_option` is the render option the provider takes it under (`nil`
  # when its widget has none, as reCAPTCHA v2's has not).
  defp widget_map(%Config{descriptor: descriptor} = config, action) do
    %{
      provider: descriptor.id,
      script_url: descriptor.script_url,
      global: descriptor.global,
      site_key: config.site_key,
      action: action_name(action),
      api: descriptor.api,
      render_options: descriptor.render_options,
      action_option: descriptor.action_option,
      onload_param: descriptor.onload_param,
      response_field: descriptor.response_field,
      interactive: descriptor.interactive
    }
  end

  @doc """
  `widget/2`'s answer as a headless client is told it — the form schema's
  `challenge` object and a refused API sign-in's `meta`: what to load
  (`script_url`, `global`, and `onload_param` when the script reports
  readiness through a named callback), what to pass `render`
  (`render_options`, `site_key`, and the `action` under `action_option` when
  that is not `null`), whether people have to interact (`interactive`) and
  which browser API that is (`api`, today always `"explicit_render"`).
  """
  @spec headless_widget(map()) :: map()
  def headless_widget(widget) do
    widget
    |> Map.take([
      :provider,
      :site_key,
      :script_url,
      :action,
      :global,
      :onload_param,
      :render_options,
      :action_option,
      :interactive
    ])
    |> Map.put(:api, to_string(widget.api))
  end

  @doc """
  Whether a form may ask for a challenge at all: a usable provider, and the
  operator has not turned forms off (`forms: false`, `CHALLENGE_FORMS`). The
  kill switch and an unusable provider both leave `provider` `nil`.
  """
  @spec forms_available?(Config.t()) :: boolean()
  def forms_available?(%Config{provider: nil}), do: false
  def forms_available?(%Config{forms: forms}), do: forms == true

  @doc """
  Whether `form`'s submissions need a challenge right now: the form asks for
  one (`challenge: :always`) and `forms_available?/1`. The form's own setting
  is clamped here on every read, so turning the operator's switch off takes
  effect everywhere at once without touching a single row.
  """
  @spec form_required?(Config.t(), map() | nil) :: boolean()
  def form_required?(%Config{} = config, %{challenge: :always}), do: forms_available?(config)
  def form_required?(%Config{}, _form), do: false

  @doc """
  What a page that draws a form's widget depends on beyond the form itself:
  the provider, the site key and a digest of the widget data the page is
  rendered with, as `"provider:site_key:digest"` — or `""` when no form can
  ask for a challenge. Part of a delivered page's ETag, so changing any of
  them (a plugin update that changes its script, say) moves it.
  """
  @spec forms_fingerprint(Config.t()) :: String.t()
  def forms_fingerprint(%Config{} = config) do
    if forms_available?(config),
      do: "#{provider_id(config)}:#{config.site_key}:#{config.descriptor.fingerprint}",
      else: ""
  end

  @doc "The mode `action` runs under."
  @spec mode_for(Config.t(), action()) :: mode()
  def mode_for(%Config{sign_in: mode}, :sign_in), do: mode
  def mode_for(%Config{registration: mode}, :register), do: mode

  @doc """
  The origins the auth pages' policy must add while a challenge can be shown
  there — empty lists otherwise (`KilnCMSWeb.Plugs.ChallengeCsp`).
  """
  @spec csp_sources(Config.t()) :: Kiln.Challenge.Provider.csp_sources()
  def csp_sources(%Config{} = config) do
    if enabled?(config),
      do: config.descriptor.csp,
      else: no_sources()
  end

  @doc """
  The origins a page drawing a form's widget must add — empty lists unless
  `forms_available?/1`. Only for a response that actually renders a form that
  needs one (`KilnCMSWeb.Plugs.ChallengeCsp.widen_for_forms/2`,
  `KilnCMSWeb.Embed.content_security_policy/2`).
  """
  @spec csp_sources(Config.t(), :forms) :: Kiln.Challenge.Provider.csp_sources()
  def csp_sources(%Config{} = config, :forms) do
    if forms_available?(config),
      do: config.descriptor.csp,
      else: no_sources()
  end

  defp no_sources, do: %{script_src: [], frame_src: [], connect_src: []}

  @doc """
  The Ash context naming where an attempt came from, merged into a sign-in's or
  a registration's `context:` by each door (`KilnCMSWeb.Plugs.SecurityContext`,
  `KilnCMSWeb.SignInLive`, `KilnCMSWeb.ApiAuthController`).

  `surface` decides whether the `api_sign_in` switch applies. `extra` carries
  the sign-in page's own presentation hints (`:preshow_sign_in`,
  `:preshow_register`, `:fallback`), which the action ignores. Deliberately no
  request host: the host a request names is the caller's to choose, so it must
  not decide which hostname a token may have been solved on (see
  `hostname_allowed?/1`).
  """
  @spec context(surface(), map()) :: map()
  def context(surface, extra \\ %{}) when surface in [:browser, :api] do
    %{@context_key => Map.put(extra, :surface, surface)}
  end

  @doc "The key `context/2` writes under."
  @spec context_key() :: atom()
  def context_key, do: @context_key

  @doc """
  Whether a token solved on `hostname` may be used here: a host this
  deployment serves (`KilnCMSWeb.Tenant.deployment_host?/1` — every site, its
  console host, the canonical base host) or one the operator listed in
  `hostnames:` (`CHALLENGE_HOSTNAMES`). An account is global, so the site a
  person solved the check on says nothing about which site's sign-in they use
  it for; a host the deployment does not serve is someone else's page.
  """
  @spec hostname_allowed?(String.t()) :: boolean()
  def hostname_allowed?(hostname) when is_binary(hostname) do
    host = hostname |> String.trim_trailing(".") |> String.downcase()

    host in Enum.map(Keyword.get(settings(), :hostnames, []), &String.downcase/1) or
      KilnCMSWeb.Tenant.deployment_host?(host)
  end

  def hostname_allowed?(_hostname), do: false

  @doc """
  Whether the provider has answered "unavailable" on this node within the
  last `outage_window` (60 s by default).

  While it has, a sign-in or registration that arrives with **no** token is
  treated as the provider being down rather than as a refusal to try: when the
  widget's own script cannot load, legitimate visitors have nothing to submit,
  and refusing them while admitting an attacker who sends junk (which reaches
  the provider and comes back unavailable) would be backwards. The same bounds
  apply to both (`KilnCMS.Challenge.Gate`).

  Node-local and short-lived on purpose: it records what this node saw, and it
  lapses on its own once the provider answers again.
  """
  @spec outage?() :: boolean()
  def outage? do
    case :persistent_term.get(@outage_key, nil) do
      until when is_integer(until) -> System.monotonic_time(:millisecond) < until
      _never -> false
    end
  end

  # Written at most twice a window: `:persistent_term.put/2` is cheap to read
  # and expensive to change, and an outage produces an unavailable answer per
  # attempt.
  defp note_outage do
    now = System.monotonic_time(:millisecond)
    window = positive(:outage_window, :timer.seconds(60))

    case :persistent_term.get(@outage_key, nil) do
      until when is_integer(until) and until - now > div(window, 2) -> :ok
      _stale -> :persistent_term.put(@outage_key, now + window)
    end
  end

  @doc false
  # Test seam: forget an outage this node noted.
  @spec clear_outage() :: :ok
  def clear_outage do
    :persistent_term.erase(@outage_key)
    :ok
  end

  @doc "A threshold or window from the operator's configuration (see the moduledoc)."
  @spec threshold(atom()) :: pos_integer()
  def threshold(:account), do: positive(:account_threshold, 3)
  def threshold(:ip), do: positive(:ip_threshold, 5)
  def threshold(:ip_window), do: positive(:ip_window, :timer.minutes(15))
  def threshold(:ip_closed_after), do: positive(:ip_closed_after, threshold(:ip) * 4)
  def threshold(:registration), do: positive(:registration_threshold, 2)
  def threshold(:registration_window), do: positive(:registration_window, :timer.hours(1))

  @doc """
  Verifies `token` for `action` with the configured provider.

  The token is checked first, with no network call: absent is `:missing`, and
  anything that is not a short printable string is `:malformed`. Then the
  provider is asked, in an unlinked task bounded by `deadline` — a crash or an
  exit is `{:unavailable, :crashed}` and the deadline passing is
  `{:unavailable, :timeout}`, so nothing a provider does can take the sign-in
  down with it. Its answer is read conservatively and its claims enforced
  (see "What the core checks" above).

  `opts`: `:hostname?` (a predicate the reported hostname must satisfy, or
  `nil` to skip the check) and `:remote_ip` (sent only when the operator
  enabled `send_remote_ip`).
  """
  @spec verify(Config.t(), term(), action(), keyword()) :: result()
  def verify(%Config{} = config, token, action, opts \\ []) do
    config |> verify_reporting(token, action, opts) |> elem(0)
  end

  @typedoc "What `verify/4` answers: a pass, or why not."
  @type result ::
          :ok
          | {:error, Kiln.Challenge.Provider.refusal() | :missing | :malformed}
          | {:error, {:unavailable, Kiln.Challenge.Provider.unavailable() | :outage}}

  @doc """
  `verify/4`, and the hostname the provider reported the token was solved on
  (`nil` when it reported none or was not asked) — for a log that names the
  host an operator should add to `CHALLENGE_HOSTNAMES`.
  """
  @spec verify_reporting(Config.t(), term(), action(), keyword()) ::
          {result(), String.t() | nil}
  def verify_reporting(%Config{} = config, token, action, opts \\ []) do
    started = System.monotonic_time()

    {result, hostname} =
      case precheck(token) do
        :ok -> ask(config, token, action, opts)
        refused -> {refused, nil}
      end

    with {:error, {:unavailable, reason}} <- result do
      # A form check never opens the outage window: that window is what lets a
      # tokenless *sign-in* through within its budget, and form posts are
      # anonymous and unthrottled per account — a burst of junk tokens drawing
      # 429s from the provider must not switch sign-in's fail-open on (#2249).
      # Forms hold everything the provider could not answer, so they need no
      # window of their own.
      if action != :form, do: note_outage()
      if reason == :not_configured, do: log_secret_refused(config)
    end

    :telemetry.execute(
      [:kiln_cms, :challenge, :verify, :stop],
      %{duration: System.monotonic_time() - started},
      %{
        provider: provider_id(config),
        action: action,
        result: result_class(result)
      }
    )

    {result, hostname}
  end

  @doc false
  # The class a result is counted and logged under: never the token, never
  # anything the provider echoed.
  @spec result_class(result()) :: atom()
  def result_class(:ok), do: :passed
  def result_class({:error, {:unavailable, reason}}) when is_atom(reason), do: reason
  def result_class({:error, reason}) when is_atom(reason), do: reason
  def result_class(_other), do: :unknown

  defp precheck(token) when token in [nil, ""], do: {:error, :missing}

  defp precheck(token) when is_binary(token) do
    if byte_size(token) <= @token_max_bytes and String.printable?(token) and
         not String.contains?(token, ["\n", "\r", "\t", <<0>>]),
       do: :ok,
       else: {:error, :malformed}
  end

  defp precheck(_token), do: {:error, :malformed}

  defp ask(config, token, action, opts) do
    case secret() do
      {:ok, secret} ->
        provider_opts = [
          secret: secret,
          action: action_name(action),
          remote_ip: if(settings()[:send_remote_ip] == true, do: Keyword.get(opts, :remote_ip)),
          post: fn url, fields -> Transport.post_form(url, fields, settings()) end
        ]

        fn -> config.provider.verify(token, provider_opts) end
        |> run_bounded()
        |> enforce_claims(action_name(action), Keyword.get(opts, :hostname?))

      {:error, _reason} ->
        {{:error, {:unavailable, :not_configured}}, nil}
    end
  end

  defp run_bounded(fun) do
    task = Task.Supervisor.async_nolink(KilnCMS.TaskSupervisor, fun)

    case Task.yield(task, deadline()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> normalize(result)
      {:exit, _reason} -> {:error, {:unavailable, :crashed}}
      nil -> {:error, {:unavailable, :timeout}}
    end
  end

  # A provider answering outside its contract is not an answer. Any refusal
  # the contract does not name — an unknown atom, a string, a tuple, a struct —
  # is still a refusal (`:invalid`), and never `:missing` or `:malformed`,
  # which only `precheck/1` may give: a missing token can be admitted during
  # an outage, and a refused one never is. Only an answer that is neither
  # `{:ok, _}` nor `{:error, _}` (or a crash) counts as the provider failing.
  # A bare `:ok` is tolerated as a pass with no claims.
  defp normalize(:ok), do: {:passed, %{}}
  defp normalize({:ok, claims}) when is_map(claims), do: {:passed, claims}
  defp normalize({:ok, _not_claims}), do: {:passed, %{}}

  defp normalize({:error, {:unavailable, reason}}) when reason in @unavailable,
    do: {:error, {:unavailable, reason}}

  defp normalize({:error, {:unavailable, _unknown}}), do: {:error, {:unavailable, :crashed}}
  defp normalize({:error, reason}) when reason in @refusals, do: {:error, reason}
  defp normalize({:error, _unknown_refusal}), do: {:error, :invalid}
  defp normalize(_other), do: {:error, {:unavailable, :crashed}}

  # The provider said the token is genuine; whether it is genuine *for this
  # deployment and this action* is the core's to decide, from what the
  # provider reported. The predicate can read the tenant table; a raise or an
  # exit there is the check being unavailable rather than a crashed request.
  # It runs in the caller, outside the provider's deadline.
  defp enforce_claims({:passed, claims}, expected_action, check) do
    hostname = claim(claims, :hostname)
    action = claim(claims, :action)

    cond do
      check != nil and not hostname_passes?(check, hostname) ->
        {{:error, :hostname_mismatch}, hostname}

      action != nil and action != expected_action ->
        {{:error, :action_mismatch}, hostname}

      true ->
        {:ok, hostname}
    end
  rescue
    _error -> {{:error, {:unavailable, :crashed}}, nil}
  catch
    :exit, _reason -> {{:error, {:unavailable, :crashed}}, nil}
  end

  defp enforce_claims(result, _expected_action, _check), do: {result, nil}

  # Atom or string keys: a provider decoding JSON may hand its answer on as is.
  defp claim(claims, key) do
    case Map.get(claims, key, Map.get(claims, Atom.to_string(key))) do
      value when is_binary(value) -> value
      _absent -> nil
    end
  end

  defp hostname_passes?(_check, nil), do: false
  defp hostname_passes?(check, hostname), do: check.(hostname) == true

  defp deadline, do: positive(:deadline, @default_deadline)

  defp provider_id(%Config{descriptor: nil}), do: nil
  defp provider_id(%Config{descriptor: descriptor}), do: descriptor.id

  defp action_name(:sign_in), do: "sign_in"
  defp action_name(:register), do: "register"
  defp action_name(:form), do: "form"

  defp off,
    do: %Config{
      provider: nil,
      descriptor: nil,
      site_key: nil,
      sign_in: :off,
      registration: :off,
      api_sign_in: false,
      forms: false
    }

  # Off without a word when the kill switch is on or no provider is named —
  # both are the operator's choice. Named but unusable is logged.
  defp usable_provider(opts) do
    id = opts[:provider]

    if opts[:disabled] == true or id in [nil, ""] do
      :off
    else
      with {:ok, descriptor} <- descriptor(id),
           {:ok, site_key} <- site_key(opts[:site_key]),
           :ok <- secret_source(opts[:secret_key]) do
        {:ok, descriptor, site_key}
      else
        problem -> unusable(id, problem)
      end
    end
  end

  defp site_key(key) when is_binary(key) and key != "", do: {:ok, key}
  defp site_key(_missing), do: :no_site_key

  # Whether a secret is *configured*, without reading it: this runs on every
  # auth page and several times per sign-in, and a read that failed once must
  # not switch the feature off for that request (it would admit the attempt
  # with no challenge). The secret is read when a token is verified, and a
  # failed read there is `:unavailable` — the bounded fail-open, not "off".
  defp secret_source({:env, %{"var" => var}}) when is_binary(var) do
    if System.get_env(var, "") |> String.trim() == "", do: :no_secret, else: :ok
  end

  defp secret_source({:file, %{"path" => path}}) when is_binary(path) and path != "", do: :ok
  defp secret_source(_other), do: :no_secret

  # Named but not usable: off, and said so (at most once a minute per node).
  defp unusable(id, problem) do
    if log_allowed?() do
      Logger.warning(unusable_message(id, problem))
    end

    :off
  end

  defp unusable_message(id, problem) do
    what =
      case problem do
        :unknown_provider ->
          "names no installed provider (installed: #{Enum.join(Registry.ids(), ", ")})"

        {:invalid_provider, problems} ->
          "names a provider that does not meet the provider contract: " <>
            Enum.join(problems, "; ")

        :no_site_key ->
          "has no site key (CHALLENGE_SITE_KEY)"

        _secret_error ->
          "has no usable secret key (CHALLENGE_SECRET_KEY or CHALLENGE_SECRET_KEY_FILE)"
      end

    "Human verification is configured (CHALLENGE_PROVIDER=#{inspect(id)}) but #{what}; " <>
      "no challenge will be required until it is fixed."
  end

  @doc """
  Why the provider the operator named cannot be used — no installed provider
  answers to the id, or it fails `Kiln.Challenge.Provider.conformance/1` — as
  a sentence for the boot log, or `nil` when it can (or none is named, or the
  kill switch is on). Missing keys are not reported here: they are logged
  when a page first asks.
  """
  @spec provider_problem() :: String.t() | nil
  def provider_problem do
    opts = settings()
    id = opts[:provider]

    if opts[:disabled] == true or id in [nil, ""] do
      nil
    else
      case descriptor(id) do
        {:ok, _descriptor} -> nil
        problem -> unusable_message(id, problem)
      end
    end
  end

  @doc """
  Reads `CHALLENGE_PROVIDER`-style input: trimmed and downcased, then held to
  the id format (`Kiln.Challenge.Provider`). `:unset` for blank. Whether a
  provider answers to the id is decided later, when it is resolved, because
  a plugin's provider is not known to runtime configuration.
  """
  @spec parse_provider_id(String.t() | nil) :: {:ok, String.t()} | :unset | :invalid
  def parse_provider_id(raw) when is_binary(raw) do
    case raw |> String.trim() |> String.downcase() do
      "" -> :unset
      id -> if Regex.match?(@provider_id, id), do: {:ok, id}, else: :invalid
    end
  end

  def parse_provider_id(nil), do: :unset

  # The provider refused the secret, or it could not be read: every check now
  # fails open (within its bounds) until an operator fixes it, so say so
  # loudly — at most once a minute per node.
  defp log_secret_refused(config) do
    allowed? =
      match?(
        {:allow, _count},
        KilnCMS.Accounts.ThrottleStore.Local.hit(
          :challenge_secret_refused_logged,
          :timer.minutes(1),
          1
        )
      )

    if allowed? do
      Logger.error(
        "Human verification (#{provider_id(config)}) could not use its secret key: " <>
          "it was refused by the provider or could not be read. Checks fail open within " <>
          "their bounds until CHALLENGE_SECRET_KEY / CHALLENGE_SECRET_KEY_FILE is fixed."
      )
    end

    :ok
  end

  defp log_allowed? do
    match?(
      {:allow, _count},
      KilnCMS.Accounts.ThrottleStore.Local.hit(:challenge_unusable_logged, :timer.minutes(1), 1)
    )
  rescue
    ArgumentError -> true
  end

  @doc "The providers an operator may name (`KilnCMS.Challenge.Registry.providers/0`)."
  @spec providers() :: [module()]
  def providers, do: Registry.providers()

  # Resolved and checked at most once per node for each provider id and
  # `providers:` value — the only parts that can change after boot (the
  # plugin list is fixed per build). One slot, so a test that cycles through
  # configurations never grows `:persistent_term`.
  defp descriptor(id) do
    cache_key = {id, Keyword.get(settings(), :providers, [])}

    case :persistent_term.get(@descriptor_key, nil) do
      {^cache_key, resolved} ->
        resolved

      _stale ->
        resolved = resolve(id)
        :persistent_term.put(@descriptor_key, {cache_key, resolved})
        resolved
    end
  end

  defp resolve(id) do
    with {:ok, module} <- Registry.fetch(id),
         {:ok, description} <- Kiln.Challenge.Provider.describe(module) do
      {:ok, to_descriptor(module, description)}
    else
      :error -> :unknown_provider
      {:error, problems} -> {:invalid_provider, problems}
    end
  rescue
    error -> {:invalid_provider, [Exception.message(error)]}
  end

  defp to_descriptor(module, %{id: id, label: label, widget: widget, csp_sources: csp}) do
    browser =
      Map.take(widget, [
        :script_url,
        :global,
        :api,
        :render_options,
        :action_option,
        :onload_param,
        :interactive
      ])

    fingerprint =
      :crypto.hash(:sha256, :erlang.term_to_binary(browser, [:deterministic]))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 12)

    struct!(
      Descriptor,
      widget
      |> Map.merge(%{id: id, label: label, module: module, csp: csp, fingerprint: fingerprint})
    )
  end

  @doc false
  # Test seam: forget the memoised provider (and the registry's response
  # fields), so a test that redefines what a provider answers sees it.
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@descriptor_key)
    Registry.reset()
  end

  defp secret do
    case KilnCMS.Keys.fetch(:challenge_secret) do
      {:ok, secret} ->
        case String.trim(secret) do
          "" -> {:error, :no_key}
          trimmed -> {:ok, trimmed}
        end

      error ->
        error
    end
  end

  defp mode(value, allowed, _default) when is_atom(value) and not is_nil(value) do
    if value in allowed, do: value, else: :off
  end

  defp mode(nil, _allowed, default), do: default
  defp mode(_other, _allowed, _default), do: :off

  defp positive(key, default) do
    case settings()[key] do
      value when is_integer(value) and value > 0 -> value
      _unset -> default
    end
  end

  defp settings, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
