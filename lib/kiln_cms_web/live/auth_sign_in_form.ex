defmodule KilnCMSWeb.AuthSignInForm do
  @moduledoc """
  `AshAuthentication.Phoenix.Components.Password.SignInForm` with an eye button
  beside the password box that shows what has been typed (#1806).

  `Components.Password`'s `sign_in_form_module` override swaps this in, on the
  same terms as `KilnCMSWeb.AuthRegisterForm`: `update/2` and every event are
  delegated to upstream, whose callbacks read only assigns and never name their
  own module, so the submit path — the sign-in throttle, the sign-in-token
  hand-off — stays the library's.

  ## Why the render is a copy

  Upstream's template names `Password.Input.password_field` directly, and that
  field has no slot or override that could put a button beside its `<input>`.
  So `render/1` below is upstream's with that one component swapped for
  `KilnCMSWeb.AuthPasswordInput.password_field/1`. Every setting in it is read
  under upstream's name through `KilnCMSWeb.AuthOverrides.override_for/4`, so
  the `override Components.Password.SignInForm` block keeps working.

  `KilnCMSWeb.AuthOverridesTest` renders this component with the toggle off and
  upstream's with the same assigns, and asserts the two are identical: an
  upstream change to this form fails that test rather than going stale here.
  """
  use KilnCMSWeb, :live_component

  import AshAuthentication.Phoenix.Components.Helpers, only: [auth_path: 5]

  alias AshAuthentication.Phoenix.Components.Password.Input
  alias AshAuthentication.Phoenix.Web
  alias KilnCMSWeb.{AuthOverrides, AuthPasswordInput}

  # Aliased, not spelled out: the template below names it, and inside `~H` a
  # `@`-prefixed name is an assign rather than a module attribute.
  alias AshAuthentication.Phoenix.Components.Password.SignInForm, as: Upstream

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
        for={@form}
        id={@form.id}
        phx-change="change"
        phx-submit="submit"
        phx-trigger-action={@trigger_action}
        phx-target={@myself}
        action={auth_path(@socket, @subject_name, @auth_routes_prefix, @strategy, :sign_in)}
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
        <%= if @inner_block do %>
          <div class={AuthOverrides.override_for(@overrides, Upstream, :slot_class)}>
            {render_slot(@inner_block, form)}
          </div>
        <% end %>

        <Input.remember_me_field
          :if={@remember_me_field}
          name={@remember_me_field}
          form={form}
          overrides={@overrides}
          gettext_fn={@gettext_fn}
        />

        <Input.submit
          strategy={@strategy}
          id={@form.id <> "-submit"}
          form={form}
          action={:sign_in}
          label={AuthOverrides.override_for(@overrides, Upstream, :button_text)}
          disable_text={AuthOverrides.override_for(@overrides, Upstream, :disable_button_text)}
          overrides={@overrides}
          gettext_fn={@gettext_fn}
        />
      </.form>

      <.form
        :if={sign_in_token_via_post?(@strategy)}
        for={%{}}
        id={@form.id <> "-sign-in-with-token"}
        action={
          auth_path(@socket, @subject_name, @auth_routes_prefix, @strategy, :sign_in_with_token)
        }
        method="POST"
        phx-trigger-action={@sign_in_token_params != nil}
        class="hidden"
      >
        <input type="hidden" name="token" value={@sign_in_token_params[:token]} />
        <input
          :if={@sign_in_token_params[:remember_me]}
          type="hidden"
          name="remember_me"
          value={@sign_in_token_params[:remember_me]}
        />
      </.form>
    </div>
    """
  end

  @impl true
  def handle_event(event, params, socket), do: Upstream.handle_event(event, params, socket)

  # Upstream's is private; the same one-line read of the strategy.
  defp sign_in_token_via_post?(strategy), do: Map.get(strategy, :sign_in_token_via_post?, false)
end
