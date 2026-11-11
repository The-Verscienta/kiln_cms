defmodule KilnCMSWeb.ConfirmLive do
  @moduledoc """
  `AshAuthentication.Phoenix.ConfirmLive` joined under Kiln's live-view macro, so
  a url-less join is refused rather than rendering the default org's branding on
  a tenant host (#701). See `KilnCMSWeb.AuthLive`.

  `mount/3` and `handle_params/3` are the macro's delegations. `render/1` is
  Kiln's (#2594): the page asks for the password chosen at sign-up as well as
  the click. Anyone can register an unconfirmed account for any address, so a
  click on the link proves only the mailbox, and confirming on that alone
  would hand its owner an account whose password a stranger chose. With the
  password as well, whoever confirms both reads the mail and chose the
  password: the account's own registrant. Anyone who did not choose it is
  pointed to a password reset, which confirms the address and removes every
  credential the earlier registrant set up (`Changes.ForgetPriorCredentials`).

  The form posts to the strategy's own route, as upstream's does; the password
  is checked by `User.:confirm_new_user`, and a wrong one comes back here
  through `KilnCMSWeb.AuthController.failure/3` with the link's token, which a
  failed confirmation does not use up.
  """
  use KilnCMSWeb.AuthLive, upstream: AshAuthentication.Phoenix.ConfirmLive

  import AshAuthentication.Phoenix.Components.Helpers, only: [auth_path: 5]
  import PhoenixHTMLHelpers.Form, only: [hidden_input: 3]

  alias AshAuthentication.Info
  alias AshAuthentication.Phoenix.Components.Confirm
  alias AshAuthentication.Phoenix.ConfirmLive, as: Upstream
  alias AshPhoenix.Form
  alias KilnCMSWeb.{AuthOverrides, AuthPasswordInput}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:confirmation, Info.strategy!(assigns.resource, assigns.strategy))
      |> assign(:password_strategy, Info.strategy!(assigns.resource, :password))
      |> then(&assign(&1, :form, confirm_form(&1)))

    ~H"""
    <div class={AuthOverrides.override_for(@overrides, Upstream, :root_class)}>
      <div class={AuthOverrides.override_for(@overrides, Confirm, :root_class)}>
        <div class={AuthOverrides.override_for(@overrides, Confirm, :strategy_class)}>
          <h2 class="auth-title mt-2 mb-2">{gettext("Confirm your email address")}</h2>
          <p class="auth-muted mb-4">
            {gettext(
              "Enter the password you chose when you signed up. It shows the account is yours as well as the address."
            )}
          </p>

          <.form
            :let={form}
            id="user-confirm-new-user-form"
            for={@form}
            action={auth_path(@socket, :user, @auth_routes_prefix, @confirmation, :confirm)}
            method="POST"
          >
            {hidden_input(form, :confirm, value: @token)}

            <AuthPasswordInput.password_field
              autocomplete="current-password"
              strategy={@password_strategy}
              form={form}
              overrides={@overrides}
              gettext_fn={@gettext_fn}
            />

            <button
              type="submit"
              class={AuthOverrides.override_for(@overrides, Confirm.Input, :submit_class)}
              phx-disable-with={gettext("Confirming...")}
            >
              {gettext("Confirm")}
            </button>
          </.form>

          <p class="auth-muted text-sm">
            {gettext("Didn't sign up, or don't remember the password?")}
            <.link navigate={~p"/reset"} class="link font-medium">
              {gettext("Reset the password instead.")}
            </.link>
            {gettext(
              "A reset confirms the address too, and removes anything someone else set up on the account."
            )}
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp confirm_form(assigns) do
    assigns.resource
    |> Form.for_action(assigns.confirmation.confirm_action_name,
      domain: Info.authentication_domain!(assigns.resource),
      as: "user",
      tenant: assigns.current_tenant,
      context: %{strategy: assigns.confirmation, private: %{ash_authentication?: true}}
    )
  end
end
