defmodule KilnCMSWeb.AuthReset do
  @moduledoc """
  `AshAuthentication.Phoenix.Components.Reset` pointed at
  `KilnCMSWeb.AuthResetForm`.

  This component does nothing of its own: upstream's `update/2` — which is where
  the resettable password strategies are discovered — is delegated, and the
  render below is upstream's with one line changed, the `module=` naming the
  form component. It exists because that line is a literal upstream, with no
  override to re-point it; `KilnCMSWeb.AuthResetForm` says why that matters.

  Because the render is a copy, it reads the settings written for the component
  it stands in for — `override Components.Reset do …` in `KilnCMSWeb.AuthOverrides`
  keeps working, and would not if this component asked for its own. See
  `KilnCMSWeb.AuthOverrides.override_for/4`.
  """
  use KilnCMSWeb, :live_component

  alias AshAuthentication.Info
  alias AshAuthentication.Phoenix.Components
  alias KilnCMSWeb.AuthOverrides

  # Not `@upstream` in the template below: inside `~H`, `@name` is an assign,
  # not a module attribute.
  @impl true
  def update(assigns, socket), do: Components.Reset.update(assigns, socket)

  @impl true
  def render(assigns) do
    ~H"""
    <div class={AuthOverrides.override_for(@overrides, Components.Reset, :root_class)}>
      <%= if AuthOverrides.override_for(@overrides, Components.Reset, :show_banner, true) do %>
        <.live_component
          module={Components.Banner}
          id="sign-in-banner"
          overrides={@overrides}
          gettext_fn={@gettext_fn}
        />
      <% end %>

      <%= for strategy <- @strategies do %>
        <div class={AuthOverrides.override_for(@overrides, Components.Reset, :strategy_class)}>
          <.live_component
            module={KilnCMSWeb.AuthResetForm}
            auth_routes_prefix={@auth_routes_prefix}
            current_tenant={@current_tenant}
            strategy={strategy}
            token={@token}
            id={"#{Info.authentication_subject_name!(strategy.resource)}-#{strategy.name}-reset-form"}
            label={false}
            overrides={@overrides}
            gettext_fn={@gettext_fn}
          />
        </div>
      <% end %>
    </div>
    """
  end
end
