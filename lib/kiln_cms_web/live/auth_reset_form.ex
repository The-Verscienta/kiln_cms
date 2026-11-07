defmodule KilnCMSWeb.AuthResetForm do
  @moduledoc """
  `AshAuthentication.Phoenix.Components.Reset.Form` — the "choose a new
  password" form behind a reset link — with the password confirmation checked as
  you type, rather than only on submit, and a submit button that says what it
  does.

  `KilnCMSWeb.AuthConfirmationFeedback` is what the `"change"` handler does
  differently and why; `update/2` and every other event are delegated, on the
  same terms as `KilnCMSWeb.AuthRegisterForm`.

  ## Why this one takes two more wrappers than the register form

  The register form is swappable by an override the library provides
  (`register_form_module`). This one is not: `AshAuthentication.Phoenix.Components.Reset`
  names `Components.Reset.Form` directly in its template, and
  `AshAuthentication.Phoenix.ResetLive` names `Components.Reset` directly in
  its. So reaching this component means re-pointing that chain —
  `KilnCMSWeb.ResetLive` → `KilnCMSWeb.AuthReset` → here.

  The token stays the library's business: `"submit"`, the hidden `reset_token`
  field and its error are delegated or copied untouched, and a bad token is
  still not reported until submit — narrowing the change event to the
  confirmation field is what keeps it that way.

  ## Why the render is a copy

  Upstream's template names `Password.Input.password_field` directly, and that
  field has no slot or override that could put a button beside its `<input>`.
  So `render/1` below is upstream's with its password boxes rendered by
  `KilnCMSWeb.AuthPasswordInput`, which puts the eye button beside each
  (#1806). Everything else in it, including the settings `override
  Components.Reset.Form` in `KilnCMSWeb.AuthOverrides` writes, is read through
  `KilnCMSWeb.AuthOverrides.override_for/4` under upstream's name, so those
  settings keep working and the copy stays a copy.

  Until ash_authentication_phoenix 3.0 the copy also existed to label the submit
  button: upstream declared no `button_text` and never passed `Input.submit` a
  label, so the button read "Reset password with token", the humanized action
  name. 3.0 declares `button_text` and passes it, so Kiln's "Change password"
  is now an ordinary setting on `Components.Reset.Form` and this render passes
  it exactly as upstream's does.

  `KilnCMSWeb.AuthOverridesTest` pins it: it renders this component and upstream's
  with the same assigns (the eye button off) and asserts they are identical.
  An upstream change to this form fails that test rather than going stale here.
  """
  use KilnCMSWeb, :live_component

  import AshAuthentication.Phoenix.Components.Helpers, only: [auth_path: 5]
  import PhoenixHTMLHelpers.Form, only: [hidden_input: 3]

  alias AshAuthentication.Phoenix.Components.Password.Input
  alias AshAuthentication.Phoenix.Web
  alias KilnCMSWeb.{AuthConfirmationFeedback, AuthOverrides, AuthPasswordInput}

  # Aliased, not spelled out: the template below names it, and inside `~H` a
  # `@`-prefixed name is an assign rather than a module attribute.
  alias AshAuthentication.Phoenix.Components.Reset.Form, as: Upstream

  @impl true
  def update(assigns, socket) do
    {:ok, socket} = Upstream.update(assigns, socket)

    {:ok, assign_new(socket, :password_reveal, fn -> true end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={AuthOverrides.override_for(@overrides, Upstream, :root_class)}>
      <%= if @label do %>
        <h2 class={AuthOverrides.override_for(@overrides, Upstream, :label_class)}>
          {Web.gettext_switch(@gettext_fn, @label, [])}
        </h2>
      <% end %>

      <.form
        :let={form}
        id={@form.id}
        for={@form}
        phx-change="change"
        phx-submit="submit"
        phx-trigger-action={@trigger_action}
        phx-target={@myself}
        action={
          auth_path(
            @socket,
            @subject_name,
            @auth_routes_prefix,
            @strategy,
            :reset
          )
        }
        method="POST"
        class={AuthOverrides.override_for(@overrides, Upstream, :form_class)}
      >
        {hidden_input(form, :reset_token, value: @token)}
        <Input.error
          field={:reset_token}
          form={@form}
          overrides={@overrides}
          gettext_fn={@gettext_fn}
        />

        <AuthPasswordInput.password_field
          autocomplete="new-password"
          strategy={@strategy}
          form={form}
          overrides={@overrides}
          gettext_fn={@gettext_fn}
          reveal={@password_reveal}
        />

        <%= if @strategy.confirmation_required? do %>
          <AuthPasswordInput.password_confirmation_field
            autocomplete="new-password"
            strategy={@strategy}
            form={form}
            overrides={@overrides}
            gettext_fn={@gettext_fn}
            reveal={@password_reveal}
          />
        <% end %>

        <div class={AuthOverrides.override_for(@overrides, Upstream, :spacer_class)}></div>

        <Input.submit
          strategy={@strategy}
          form={form}
          action={:reset}
          label={AuthOverrides.override_for(@overrides, Upstream, :button_text)}
          disable_text={
            Web.gettext_switch(
              @gettext_fn,
              AuthOverrides.override_for(@overrides, Upstream, :disable_button_text),
              []
            )
          }
          overrides={@overrides}
          gettext_fn={@gettext_fn}
        />
      </.form>
    </div>
    """
  end

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

  def handle_event(event, params, socket), do: Upstream.handle_event(event, params, socket)
end
