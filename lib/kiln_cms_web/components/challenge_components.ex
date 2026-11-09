defmodule KilnCMSWeb.ChallengeComponents do
  @moduledoc """
  The human-verification widget on the sign-in and registration forms (#2249),
  and the state those forms keep about it.

  ## Nothing until it is needed

  `challenge_widget/1` renders **nothing** unless a provider is configured for
  the action *and* the form has decided to show it — so with the feature off,
  or for the many visitors who never cross a threshold, the forms are exactly
  the library's (`KilnCMSWeb.AuthOverridesTest` holds them to that). It is
  shown from the first render when the page already knows a challenge will be
  needed (registration `:always`, the caller's address past its threshold,
  `?challenge=1` after a refused form POST), and otherwise after the action
  refuses an attempt with `KilnCMS.Accounts.Errors.ChallengeRequired`.

  ## No inline script

  The markup carries everything as `data-` attributes and the `Challenge` hook
  (`assets/js/challenge.js`) does the rest: it loads the provider's script once,
  draws the widget when the element is actually visible (the three auth forms
  share a page and two are hidden), writes the token into the hidden input,
  clears it when it expires, and shows the fallback line when the script cannot
  load. The policy allows the provider's origin only while this can be drawn
  (`KilnCMSWeb.Plugs.ChallengeCsp`).

  ## A spent token is a new widget

  A token is good for one verification. Every submit that carried one has
  spent it, so the form bumps `generation`, which is part of the hook
  element's id: LiveView replaces the element, the old widget is removed and a
  fresh one drawn. `phx-update="ignore"` keeps every other render from touching
  the provider's iframe or the token.
  """
  use Phoenix.Component
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.Accounts.Errors.ChallengeRequired
  alias KilnCMS.Challenge

  @typedoc "What a form keeps about its challenge."
  @type state :: %{
          widget: map() | nil,
          shown: boolean(),
          reason: ChallengeRequired.reason() | nil,
          generation: non_neg_integer(),
          fallback: [atom()]
        }

  @doc """
  The initial state for `action`'s form, from the form's Ash `context` (where
  `KilnCMSWeb.SignInLive` puts the page's hints under
  `KilnCMS.Challenge.context_key/0`).
  """
  @spec initial(Challenge.action(), map() | nil) :: state()
  def initial(action, context) do
    hints = hints(context)
    widget = Challenge.widget(Challenge.config(), action)

    %{
      widget: widget,
      shown: widget != nil and Map.get(hints, preshow_key(action), false) == true,
      reason: nil,
      generation: 0,
      fallback: Map.get(hints, :fallback, [])
    }
  end

  @doc """
  The state after a submit: shown with the refusal's reason when the action
  asked for a challenge, and always a fresh widget when one was showing, since
  the attempt spent its token. `source` is the form's source after the submit.
  """
  @spec after_submit(state(), term()) :: state()
  def after_submit(%{widget: nil} = state, _source), do: state

  def after_submit(state, source) do
    case ChallengeRequired.find(source) do
      %ChallengeRequired{reason: reason} ->
        %{state | shown: true, reason: reason, generation: state.generation + 1}

      nil ->
        if state.shown,
          do: %{state | reason: nil, generation: state.generation + 1},
          else: state
    end
  end

  defp preshow_key(:sign_in), do: :preshow_sign_in
  defp preshow_key(:register), do: :preshow_register

  defp hints(%{} = context) do
    case Map.get(context, Challenge.context_key()) do
      %{} = hints -> hints
      _none -> %{}
    end
  end

  defp hints(_context), do: %{}

  attr :id, :string, required: true, doc: "The form's id; the widget's id derives from it."
  attr :state, :map, required: true

  attr :name, :string,
    required: true,
    doc: "The hidden input's name, e.g. `user[challenge_token]`."

  attr :action, :atom, required: true, values: [:sign_in, :register]

  @doc "The widget, or nothing when it is not configured or not shown."
  def challenge_widget(%{state: %{widget: widget, shown: true}} = assigns)
      when is_map(widget) do
    ~H"""
    <div class="mt-4 mb-2" data-role="challenge">
      <p
        :if={@state.reason}
        id={"#{@id}-challenge-reason"}
        role="alert"
        class="mb-2 text-sm text-error"
      >
        {reason_text(@state.reason, @action)}
      </p>
      <div
        id={"#{@id}-challenge-#{@state.generation}"}
        phx-hook="Challenge"
        phx-update="ignore"
        data-script-url={@state.widget.script_url}
        data-global={@state.widget.global}
        data-sitekey={@state.widget.site_key}
        data-action={@state.widget.action}
        data-loading-text={gettext("Loading the human-verification check…")}
        data-solved-text={gettext("Check complete.")}
        data-expired-text={gettext("The check expired. Complete it again.")}
        data-error-text={gettext("The human-verification check could not load.")}
      >
        <input type="hidden" name={@name} value="" data-role="challenge-token" />
        <div data-role="challenge-widget"></div>
        <p class="auth-muted mt-1 text-xs" role="status" data-role="challenge-status"></p>
        <p class="auth-muted mt-1 text-xs" data-role="challenge-fallback" hidden>
          {fallback_text(@action, @state.fallback)}
        </p>
      </div>
      <noscript>
        <p class="auth-muted mt-1 text-xs">
          {gettext("This check needs JavaScript.")} {fallback_text(@action, @state.fallback)}
        </p>
      </noscript>
    </div>
    """
  end

  def challenge_widget(assigns), do: ~H""

  @doc "The sentence that says why a challenge is showing — also the no-JS form POST's flash."
  @spec reason_text(ChallengeRequired.reason(), Challenge.action()) :: String.t()
  def reason_text(:required, :sign_in),
    do: gettext("Complete the human-verification check below, then sign in again.")

  def reason_text(:required, :register),
    do: gettext("Complete the human-verification check below, then register again.")

  def reason_text(:failed, _action),
    do: gettext("The human-verification check didn't pass. Complete it again.")

  def reason_text(:unavailable, _action),
    do: gettext("The human-verification check is unavailable right now. Try again in a moment.")

  @doc """
  The line offering another way in, naming only the ways this page has: a
  passkey (always, where the browser supports one), a sign-in link by email
  when the magic-link strategy is on, and the site's own single sign-on when it
  has a usable one. Registration offers an invitation from a site's admin,
  which needs no challenge.
  """
  @spec fallback_text(Challenge.action(), [atom()]) :: String.t()
  def fallback_text(:register, _options),
    do: gettext("Can't complete the check? Ask a site administrator to invite you instead.")

  def fallback_text(:sign_in, options) do
    case {:magic_link in options, :site_sso in options} do
      {true, true} ->
        gettext(
          "Can't complete the check? Use a passkey, email yourself a sign-in link, or use your site's single sign-on."
        )

      {true, false} ->
        gettext("Can't complete the check? Use a passkey or email yourself a sign-in link.")

      {false, true} ->
        gettext("Can't complete the check? Use a passkey or your site's single sign-on.")

      {false, false} ->
        gettext("Can't complete the check? Use a passkey instead.")
    end
  end
end
