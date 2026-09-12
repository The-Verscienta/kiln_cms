defmodule KilnCMSWeb.ResetLive do
  @moduledoc """
  `AshAuthentication.Phoenix.ResetLive` joined under Kiln's live-view macro, so
  a url-less join is refused rather than rendering the default org's branding on
  a tenant host (#701). See `KilnCMSWeb.AuthLive`.

  `mount/3` and `handle_params/3` are the macro's delegations. `render/1` is not:
  it is upstream's with one line changed, the `module=` naming the component
  below it, so that the reset form is Kiln's and the password confirmation is
  checked as it is typed. `KilnCMSWeb.AuthResetForm` says why that cannot be
  done with an override.
  """
  use KilnCMSWeb.AuthLive, upstream: AshAuthentication.Phoenix.ResetLive

  # Aliased, not spelled out: `ResetLive` unqualified in this module would read
  # as this module rather than the one whose settings the copied render draws.
  alias AshAuthentication.Phoenix.ResetLive, as: Upstream
  alias KilnCMSWeb.AuthOverrides

  @impl true
  def render(assigns) do
    ~H"""
    <div class={AuthOverrides.override_for(@overrides, Upstream, :root_class)}>
      <.live_component
        module={KilnCMSWeb.AuthReset}
        otp_app={@otp_app}
        id={AuthOverrides.override_for(@overrides, Upstream, :reset_id, "reset")}
        token={@token}
        auth_routes_prefix={@auth_routes_prefix}
        overrides={@overrides}
        current_tenant={@current_tenant}
        context={@context}
        gettext_fn={@gettext_fn}
        resources={@resources}
      />
    </div>
    """
  end
end
