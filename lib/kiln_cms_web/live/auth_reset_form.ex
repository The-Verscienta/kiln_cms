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

  Upstream's `Input.submit` takes the button's wording as a `label` prop and
  falls back to humanizing the action name when it is not given one. Upstream's
  render never passes it, so the button on `/password-reset/:token` read
  "Reset password with token" — an internal action name, on the same button that
  then says "Changing password ..." while it works. `Components.Reset.Form`
  declares no `button_text` override to fix that with, which leaves passing the
  prop, which means owning the render.

  So this module declares the `button_text` the component it stands in for
  lacks, and `render/1` below is upstream's with that one prop added. Everything
  else in it — including the four settings `override Components.Reset.Form` in
  `KilnCMSWeb.AuthOverrides` writes — is read through
  `KilnCMSWeb.AuthOverrides.override_for/4` under upstream's name, so those
  settings keep working and the copy stays a copy.

  `KilnCMSWeb.AuthOverridesTest` pins it: it renders this component and upstream's
  with the same assigns and asserts the only difference is the button's wording.
  An upstream change to this form fails that test rather than going stale here.
  """
  use KilnCMSWeb, :live_component

  use AshAuthentication.Phoenix.Overrides.Overridable,
    button_text: "Text for the submit button."

  import AshAuthentication.Phoenix.Components.Helpers, only: [auth_path: 5]
  import PhoenixHTMLHelpers.Form, only: [hidden_input: 3]

  alias AshAuthentication.Phoenix.Components.Password.Input
  alias AshAuthentication.Phoenix.Web
  alias KilnCMSWeb.{AuthConfirmationFeedback, AuthOverrides}

  # Aliased, not spelled out: the template below names it, and inside `~H` a
  # `@`-prefixed name is an assign rather than a module attribute.
  alias AshAuthentication.Phoenix.Components.Reset.Form, as: Upstream

  @impl true
  def update(assigns, socket) do
    {:ok, socket} = Upstream.update(assigns, socket)

    {:ok, assign(socket, :submit_label, submit_label(socket.assigns.overrides))}
  end

  # Passed to `Input.submit` as attributes rather than as a `label={...}` that
  # may be nil, because nil is not how that component spells "no label given":
  # it fills the prop in with `assign_new/3`, so an unset `button_text` has to
  # arrive as an absent attribute to get upstream's wording back.
  defp submit_label(overrides) do
    case override_for(overrides, :button_text) do
      nil -> []
      text -> [label: text]
    end
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

        <Input.password_field
          strategy={@strategy}
          form={form}
          overrides={@overrides}
          gettext_fn={@gettext_fn}
        />

        <%= if @strategy.confirmation_required? do %>
          <Input.password_confirmation_field
            strategy={@strategy}
            form={form}
            overrides={@overrides}
            gettext_fn={@gettext_fn}
          />
        <% end %>

        <div class={AuthOverrides.override_for(@overrides, Upstream, :spacer_class)}></div>

        <Input.submit
          strategy={@strategy}
          form={form}
          action={:reset}
          disable_text={
            Web.gettext_switch(
              @gettext_fn,
              AuthOverrides.override_for(@overrides, Upstream, :disable_button_text),
              []
            )
          }
          overrides={@overrides}
          gettext_fn={@gettext_fn}
          {@submit_label}
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
