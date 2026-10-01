defmodule KilnCMSWeb.AuthRegisterForm do
  @moduledoc """
  `AshAuthentication.Phoenix.Components.Password.RegisterForm` with the password
  confirmation checked as you type, rather than only on submit.

  `KilnCMSWeb.AuthConfirmationFeedback` is what the `"change"` handler does
  differently and why. The render is upstream's with its two password boxes
  swapped for `KilnCMSWeb.AuthPasswordInput`'s, which add the eye button that
  shows what has been typed (#1806); everything else here is delegation.

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

  `render/1` is the exception, and a copy only because upstream's names
  `Input.password_field` directly: there is no other way to put a button beside
  the password box. Every setting in it is read under upstream's name through
  `KilnCMSWeb.AuthOverrides.override_for/4`, and `KilnCMSWeb.AuthOverridesTest`
  renders it with the toggle off against upstream's and asserts the two are
  identical, so an upstream change fails a test instead of going stale here.
  """
  use KilnCMSWeb, :live_component

  import AshAuthentication.Phoenix.Components.Helpers, only: [auth_path: 5]

  alias AshAuthentication.Phoenix.Components.Password.Input
  alias KilnCMSWeb.{AuthConfirmationFeedback, AuthOverrides, AuthPasswordInput}

  # Aliased, not spelled out: the template below names it, and inside `~H` a
  # `@`-prefixed name is an assign rather than a module attribute.
  alias AshAuthentication.Phoenix.Components.Password.RegisterForm, as: Upstream

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
          {@label}
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
        action={auth_path(@socket, @subject_name, @auth_routes_prefix, @strategy, :register)}
        method="POST"
        class={AuthOverrides.override_for(@overrides, Upstream, :form_class)}
      >
        <Input.identity_field
          strategy={@strategy}
          form={form}
          overrides={@overrides}
          gettext_fn={@gettext_fn}
        />
        <AuthPasswordInput.password_field
          strategy={@strategy}
          form={form}
          overrides={@overrides}
          gettext_fn={@gettext_fn}
          reveal={@password_reveal}
        />

        <%= if @strategy.confirmation_required? do %>
          <AuthPasswordInput.password_confirmation_field
            strategy={@strategy}
            form={form}
            overrides={@overrides}
            gettext_fn={@gettext_fn}
            reveal={@password_reveal}
          />
        <% end %>

        <%= if @inner_block do %>
          <div class={AuthOverrides.override_for(@overrides, Upstream, :slot_class)}>
            {render_slot(@inner_block, form)}
          </div>
        <% end %>

        <Input.submit
          strategy={@strategy}
          form={form}
          action={:register}
          label={AuthOverrides.override_for(@overrides, Upstream, :button_text)}
          disable_text={AuthOverrides.override_for(@overrides, Upstream, :disable_button_text)}
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
