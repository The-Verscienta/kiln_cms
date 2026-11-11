defmodule KilnCMSWeb.AuthResetRequestForm do
  @moduledoc """
  `AshAuthentication.Phoenix.Components.Password.ResetForm` — the "email me a
  reset link" form on `/reset` — with `autocomplete="email"` on its email box
  (#2162).

  `Components.Password`'s `reset_form_module` override swaps this in, on the
  same terms as `KilnCMSWeb.AuthSignInForm`: `update/2` and every event are
  delegated to upstream, whose callbacks read only assigns and never name their
  own module, so the request, the confirmation flash and the form reset after
  it stay the library's.

  ## Why the render is a copy

  Upstream's template names `Password.Input.identity_field` directly, and that
  field takes no `autocomplete`. So `render/1` below is upstream's with that one
  component swapped for `KilnCMSWeb.AuthIdentityInput.identity_field/1`, and
  every setting read under upstream's name through
  `KilnCMSWeb.AuthOverrides.override_for/4`. `KilnCMSWeb.AuthOverridesTest`
  renders it against `Password.ResetForm` and asserts they differ by nothing
  but `autocomplete`, so an upstream change to the form fails that test rather
  than going stale here (#2389).
  """
  use KilnCMSWeb, :live_component

  import AshAuthentication.Phoenix.Components.Helpers, only: [auth_path: 5]

  alias AshAuthentication.Phoenix.Components.Password.Input
  alias KilnCMSWeb.{AuthIdentityInput, AuthOverrides}

  # Aliased, not spelled out: the template below names it, and inside `~H` a
  # `@`-prefixed name is an assign rather than a module attribute.
  alias AshAuthentication.Phoenix.Components.Password.ResetForm, as: Upstream

  @impl true
  def update(assigns, socket), do: Upstream.update(assigns, socket)

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
        for={@form}
        id={@form.id}
        phx-submit="submit"
        phx-change="change"
        phx-target={@myself}
        action={
          auth_path(
            @socket,
            @subject_name,
            @auth_routes_prefix,
            @strategy,
            :reset_request
          )
        }
        method="POST"
        class={AuthOverrides.override_for(@overrides, Upstream, :form_class)}
      >
        <AuthIdentityInput.identity_field
          strategy={@strategy}
          form={form}
          overrides={@overrides}
          gettext_fn={@gettext_fn}
        />

        <%= if @inner_block do %>
          <div class={AuthOverrides.override_for(@overrides, Upstream, :slot_class)}>
            {render_slot(@inner_block, form)}
          </div>
        <% end %>

        <Input.submit
          strategy={@strategy}
          form={form}
          action={:request_reset}
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
  def handle_event(event, params, socket), do: Upstream.handle_event(event, params, socket)
end
