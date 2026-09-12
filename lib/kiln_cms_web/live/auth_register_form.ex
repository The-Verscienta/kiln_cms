defmodule KilnCMSWeb.AuthRegisterForm do
  @moduledoc """
  `AshAuthentication.Phoenix.Components.Password.RegisterForm` with the password
  confirmation checked as you type, rather than only on submit.

  ## The behaviour this changes

  Upstream's `"change"` handler validates with `errors: false`:

      socket.assigns.form |> Form.validate(params, errors: false)

  That is the right default for the form as a whole — with errors on, "is
  required" appears under the email field on the first keystroke of it, before
  the visitor has had a chance to be wrong. But it also holds back the one
  error the visitor *has* already made and can already see: two password boxes
  that do not agree. Today that surfaces only after a submit round trip, which
  on the register form also clears the password field, so a typo in the
  confirmation costs re-typing both.

  So the change here is deliberately narrow. `"change"` still validates with
  `errors: false`, and the result is then re-marked as displaying errors with
  every error *except* the ones on the confirmation field filtered out, and only
  once the visitor has typed something into that box. Nothing else about the
  page moves: the email and password fields stay quiet until submit, exactly as
  before, and submit still reports everything.

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

  ## The reset page

  `/reset/:token` has the same two boxes and the same late feedback, but
  `AshAuthentication.Phoenix.Components.Reset` hardcodes its form component with
  no override to point elsewhere, so closing it there means copying a view
  rather than swapping a module. Left alone deliberately.
  """
  use KilnCMSWeb, :live_component

  alias AshPhoenix.Form

  @upstream AshAuthentication.Phoenix.Components.Password.RegisterForm

  @impl true
  def update(assigns, socket), do: @upstream.update(assigns, socket)

  @impl true
  def render(assigns), do: @upstream.render(assigns)

  @impl true
  def handle_event("change", params, socket) do
    params = strategy_params(params, socket.assigns.form)

    form =
      socket.assigns.form
      |> Form.validate(params, errors: false)
      |> reveal_confirmation_error(params, socket.assigns.strategy)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event(event, params, socket), do: @upstream.handle_event(event, params, socket)

  # Upstream's private `get_params/2` rebuilds this key by slugifying the
  # subject name. `form.name` is the same string arrived at from the other end:
  # it is the `as:` the form was built with, and so the key the browser posts
  # under.
  defp strategy_params(params, form), do: Map.get(params, form.name, %{})

  # `Form.validate(errors: false)` has already run every validation — the
  # confirmation check among them — and only suppressed the display. So this
  # does not re-derive the mismatch: it takes the error the changeset already
  # holds and narrows what the form is willing to show to that field.
  #
  # Both of the fields written here are the documented seam for this.
  # `AshPhoenix.Form.add_error/3` says outright that the form's `errors` field
  # has to be true for an error to be visible, and the source's error list is
  # what `Form.errors/1` reads through the form's `transform_errors`. The
  # narrowed list does not survive the next event either way: `"change"` and
  # `"submit"` both rebuild the changeset from the action and the params, so
  # what is dropped here is recomputed rather than lost.
  defp reveal_confirmation_error(form, params, strategy) do
    field = strategy.password_confirmation_field
    errors = Enum.filter(form.source.errors, &(Map.get(&1, :field) == field))

    if errors == [] or not typed?(Map.get(params, to_string(field))) do
      form
    else
      %{form | errors: true, source: %{form.source | errors: errors}}
    end
  end

  # An empty confirmation box is a visitor who has not got there yet, not a
  # mismatch. Deliberately not trimmed: whitespace is a legitimate password
  # character, so " " is something they typed.
  defp typed?(value) when is_binary(value), do: value != ""
  defp typed?(_value), do: false
end
