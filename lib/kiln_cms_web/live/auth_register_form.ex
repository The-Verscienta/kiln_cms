defmodule KilnCMSWeb.AuthRegisterForm do
  @moduledoc """
  `AshAuthentication.Phoenix.Components.Password.RegisterForm` with the password
  confirmation checked as you type, rather than only on submit.

  `KilnCMSWeb.AuthConfirmationFeedback` is what the `"change"` handler does
  differently and why; everything else here is delegation.

  ## Why a wrapper rather than a copy

  `Components.Password`'s `register_form_module` override exists to swap this
  component, and everything below the change handler — the template, the field
  components, the submit path, the sign-in-token exchange — stays the library's.
  `update/2`, `render/1` and every event other than `"change"` are delegated, so
  an upstream change to the register form arrives with the dependency instead of
  being frozen here. This is the same trade `KilnCMSWeb.AuthLive` and
  `KilnCMSWeb.SignInLive` make on the views above it.

  The delegation is safe because the upstream callbacks read only assigns —
  `@form`, `@strategy`, `@subject_name`, `@auth_routes_prefix` — and never name
  their own module, so they operate on this component's socket and the rendered
  form's `phx-target` is this component's `@myself`.
  """
  use KilnCMSWeb, :live_component

  alias KilnCMSWeb.AuthConfirmationFeedback

  @upstream AshAuthentication.Phoenix.Components.Password.RegisterForm

  @impl true
  def update(assigns, socket), do: @upstream.update(assigns, socket)

  @impl true
  def render(assigns), do: @upstream.render(assigns)

  @impl true
  def handle_event("change", params, socket) do
    form =
      AuthConfirmationFeedback.validate_change(
        socket.assigns.form,
        params,
        socket.assigns.strategy
      )

    {:noreply, assign(socket, form: form)}
  end

  def handle_event(event, params, socket), do: @upstream.handle_event(event, params, socket)
end
