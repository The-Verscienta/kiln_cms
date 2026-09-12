defmodule KilnCMSWeb.AuthResetForm do
  @moduledoc """
  `AshAuthentication.Phoenix.Components.Reset.Form` — the "choose a new
  password" form behind a reset link — with the password confirmation checked as
  you type, rather than only on submit.

  `KilnCMSWeb.AuthConfirmationFeedback` is what the `"change"` handler does
  differently and why; everything else here is delegation, on the same terms as
  `KilnCMSWeb.AuthRegisterForm`.

  ## Why this one takes two more wrappers than the register form

  The register form is swappable by an override the library provides
  (`register_form_module`). This one is not: `AshAuthentication.Phoenix.Components.Reset`
  names `Components.Reset.Form` directly in its template, and
  `AshAuthentication.Phoenix.ResetLive` names `Components.Reset` directly in
  its. So reaching this component means re-pointing that chain —
  `KilnCMSWeb.ResetLive` → `KilnCMSWeb.AuthReset` → here — and those two copy a
  render each. Nothing else is copied, and the copies are the only place an
  upstream change to the reset page can go stale.

  The token stays the library's business: `"submit"`, the hidden `reset_token`
  field and its error are delegated untouched, and a bad token is still not
  reported until submit — narrowing the change event to the confirmation field
  is what keeps it that way.
  """
  use KilnCMSWeb, :live_component

  alias KilnCMSWeb.AuthConfirmationFeedback

  @upstream AshAuthentication.Phoenix.Components.Reset.Form

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
