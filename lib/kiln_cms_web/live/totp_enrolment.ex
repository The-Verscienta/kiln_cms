defmodule KilnCMSWeb.TotpEnrolment do
  @moduledoc """
  Setting up an authenticator app, shared by the two pages that offer it
  (#2247): `KilnCMSWeb.SettingsLive` (`/editor/settings`) and
  `KilnCMSWeb.TwoFactorSetupLive` (`/account/two-factor`).

  One flow, so the two pages cannot disagree about it: `start/1` stages a new
  secret (`User.:setup_totp`) and assigns what the QR code shows, `confirm/3`
  proves a code from it (`User.:confirm_totp`) and assigns the one-time
  recovery codes, `cancel/1` drops the staged state. The events stay on each
  page; these are what its handlers call.

  The assigns it reads and writes:

    * `:current_user` — replaced with the updated account;
    * `:enrolling` — `nil`, or the staged secret, its `otpauth://` URI and QR;
    * `:totp_enabled?` — whether an authenticator app is confirmed;
    * `:recovery_login?` — whether this session signed in with a recovery
      code (#786), from the session, never the client;
    * `:recovery_codes` — the codes a confirmation just minted, shown once;
    * `:security_context` — the action context the change is logged with.

  `confirm/3` takes the action context to add (the email proof's, see
  `KilnCMS.Accounts.EnrolmentProof`); the action decides, not this module.
  """
  use KilnCMSWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.DemoAccountLocked
  alias KilnCMS.Accounts.Errors.EnrolmentProofRequired
  alias KilnCMS.Accounts.Errors.LastSecondFactorRequired
  alias KilnCMS.Accounts.Errors.SecondFactorThrottled
  alias KilnCMS.Accounts.Totp

  @doc """
  The assigns a page starts with. `session` is the LiveView session: whether
  it signed in with a recovery code is read from it.
  """
  @spec init(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def init(socket, session) do
    socket
    |> assign(:totp_enabled?, Accounts.totp_enabled?(socket.assigns.current_user))
    # Whether THIS session signed in with a recovery code (#786). Set by the
    # 2FA gate; read here so re-enrolling over a live secret can waive the
    # current-code proof for someone who lost their authenticator.
    |> assign(:recovery_login?, session["totp_recovery_login"] == true)
    # Transient enrolment state (secret + provisioning URI + QR) while confirming.
    |> assign(:enrolling, nil)
    # Freshly minted recovery codes, shown exactly once (#331 phase 2).
    |> assign(:recovery_codes, nil)
  end

  @doc "Stage a new secret and show it, or flash why not."
  @spec start(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def start(socket) do
    user = socket.assigns.current_user

    case Accounts.setup_totp(user, %{}, actor: user) do
      {:ok, user} ->
        uri = Totp.otpauth_uri(user.totp_pending_secret, to_string(user.email))

        socket
        |> assign(:current_user, user)
        |> assign(:enrolling, %{
          secret: Totp.base32_encode(user.totp_pending_secret),
          uri: uri,
          qr_svg: qr_svg(uri)
        })

      {:error, error} ->
        put_flash(
          socket,
          :error,
          error_message(error, gettext("Couldn't start two-factor setup."))
        )
    end
  end

  @doc "Drop the staged state. The staged secret enforces nothing."
  @spec cancel(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def cancel(socket), do: assign(socket, :enrolling, nil)

  @doc """
  Confirm the staged secret with `params["code"]` (and `params["current_code"]`
  when replacing a confirmed one). `context` is merged into the action's
  context over the page's `:security_context`.

  `{:ok, socket}` with the recovery codes assigned and a flash, or
  `{:error, socket}` with a flash saying why.
  """
  @spec confirm(Phoenix.LiveView.Socket.t(), map(), map()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def confirm(socket, %{"code" => code} = params, context) when is_binary(code) do
    user = socket.assigns.current_user

    args = %{
      code: code,
      # Only meaningful when replacing an already-confirmed secret (#786); the
      # action ignores both on a first enrolment. `recovery_login?` comes from
      # the session, not this payload — the current-code field is the only thing
      # the form contributes.
      current_code: params["current_code"],
      recovery_login?: socket.assigns.recovery_login?
    }

    case Accounts.confirm_totp(user, args,
           actor: user,
           context: Map.merge(socket.assigns.security_context, context)
         ) do
      {:ok, user} ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:totp_enabled?, true)
         |> assign(:enrolling, nil)
         |> assign(:recovery_codes, Ash.Resource.get_metadata(user, :recovery_codes))
         |> put_flash(:info, gettext("Two-factor authentication is now on."))}

      {:error, error} ->
        {:error,
         put_flash(
           socket,
           :error,
           error_message(error, gettext("That code isn't valid — try again."))
         )}
    end
  end

  @doc """
  What to tell the person about a refused second-factor action: the budget
  is spent, the account is the shared demo one, the email proof is missing,
  the factor is the last one a site requires, or `fallback`. Takes an Ash error, a changeset, or what an `{:error, _}`
  held.
  """
  @spec error_message(term(), String.t()) :: String.t()
  def error_message(%{errors: errors}, fallback) do
    Enum.find_value(List.wrap(errors), fallback, fn
      %SecondFactorThrottled{retry_after_seconds: seconds} ->
        gettext("Too many attempts — try again in %{seconds} seconds.", seconds: seconds)

      %DemoAccountLocked{} ->
        demo_locked_message()

      %EnrolmentProofRequired{} ->
        gettext("Confirm your email address before adding a second factor.")

      %LastSecondFactorRequired{} ->
        last_factor_message()

      _other ->
        nil
    end)
  end

  def error_message({:error, error}, fallback), do: error_message(error, fallback)
  def error_message(_error, fallback), do: fallback

  @doc "Why an account's last second factor can't be removed (#2247)."
  @spec last_factor_message() :: String.t()
  def last_factor_message do
    gettext(
      "A site you use requires two-step sign-in, so you can't remove your last second factor. Add another one first."
    )
  end

  @doc "Why the shared demo account's sign-in methods can't be changed."
  @spec demo_locked_message() :: String.t()
  def demo_locked_message do
    gettext(
      "This is a shared demo account, so its password and sign-in methods can't be changed."
    )
  end

  attr :enrolling, :map, required: true, doc: "the staged secret, URI and QR"

  @doc "The staged secret and the form that confirms it."
  def setup(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/70">
        {gettext(
          "Scan the QR code (or add the key) in your authenticator app, then enter the 6-digit code to confirm."
        )}
      </p>
      <.totp_qr :if={@enrolling.qr_svg} svg={@enrolling.qr_svg} />
      <p class="text-sm">
        {gettext("Setup key")}:
        <code class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-sm break-all">{@enrolling.secret}</code>
      </p>
      <details class="text-xs text-base-content/70">
        <summary class="cursor-pointer">{gettext("Provisioning URI")}</summary>
        <code class="break-all">{@enrolling.uri}</code>
      </details>
      <form id="confirm-totp-form" phx-submit="confirm_totp" class="flex items-end gap-2">
        <.input
          name="code"
          value=""
          type="text"
          inputmode="numeric"
          autocomplete="one-time-code"
          label={gettext("6-digit code")}
        />
        <.button type="submit" variant="primary">{gettext("Confirm")}</.button>
        <button type="button" phx-click="cancel_totp" class="btn btn-default">
          {gettext("Cancel")}
        </button>
      </form>
    </div>
    """
  end

  @doc """
  That adding or replacing the app sends the owner a mail (#2828, #2886):
  `User.:confirm_totp` mails on a first setup and a replacement alike
  (`NotifyFactorAdded`). Drawn beside a control that starts or confirms one,
  never where none is shown.
  """
  def added_mail_note(assigns) do
    ~H"""
    <p id="totp-added-mail" class="mt-3 text-xs text-base-content/70">
      {gettext("We'll email you when an authenticator app is added or replaced.")}
    </p>
    """
  end

  attr :codes, :list, required: true

  @doc "The recovery codes a confirmation just minted, shown once."
  def recovery_codes(assigns) do
    ~H"""
    <div class="mb-4 space-y-2 rounded-lg border border-warning/50 bg-warning/10 p-4">
      <p class="text-sm font-medium">
        {gettext("Your recovery codes — save them now, they won't be shown again.")}
      </p>
      <p class="text-xs text-base-content/70">
        {gettext("Each code signs you in once if you lose your authenticator.")}
      </p>
      <ul
        class="grid grid-cols-2 gap-x-6 gap-y-1 font-mono text-sm"
        data-role="recovery-codes"
      >
        <li :for={code <- @codes}>{code}</li>
      </ul>
      <button
        type="button"
        phx-click="dismiss_recovery_codes"
        class="btn btn-sm btn-default"
      >
        {gettext("I've saved them")}
      </button>
    </div>
    """
  end

  defp qr_svg(uri) do
    uri |> EQRCode.encode() |> EQRCode.svg(width: 176)
  rescue
    _ -> nil
  end

  attr :svg, :string, required: true

  # The SVG is generated locally by EQRCode from the otpauth URI we built —
  # never from user input — so rendering it raw is safe.
  # sobelow_skip ["XSS.Raw"]
  defp totp_qr(assigns) do
    ~H"""
    <div class="w-fit rounded-lg bg-white p-2" data-role="totp-qr">
      {Phoenix.HTML.raw(@svg)}
    </div>
    """
  end
end
