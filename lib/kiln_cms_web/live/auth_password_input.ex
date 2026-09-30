defmodule KilnCMSWeb.AuthPasswordInput do
  @moduledoc """
  The password boxes on the sign-in, register and reset-password forms, each
  with an eye button that shows what has been typed (#1806).

  These are `AshAuthentication.Phoenix.Components.Password.Input.password_field/1`
  and `password_confirmation_field/1`, copied, with one addition: when `reveal`
  is on (the default) the input sits in a `relative` wrapper beside
  `KilnCMSWeb.CoreComponents.password_reveal/1`, and takes `pr-10` so the text
  never runs under the button. The toggle itself is described there.

  ## Why a copy

  Upstream's field renders its `<input>` through `password_input/3` with no slot
  and no override that could put anything next to it, and every form names
  `Input.password_field` directly. So the three forms that show a password box —
  `KilnCMSWeb.AuthSignInForm`, `KilnCMSWeb.AuthRegisterForm` and
  `KilnCMSWeb.AuthResetForm` — render these instead.

  Every setting is still read under upstream's name, through
  `KilnCMSWeb.AuthOverrides.override_for/4`, so the `override Components.Password.Input`
  block in `KilnCMSWeb.AuthOverrides` keeps styling these boxes. With
  `reveal={false}` the markup is byte-identical to upstream's, and
  `KilnCMSWeb.AuthOverridesTest` holds each form to that: an upstream change to
  a field fails the test rather than going stale here.
  """
  use Phoenix.Component

  import KilnCMSWeb.CoreComponents, only: [password_reveal: 1]
  import Phoenix.HTML.Form, only: [input_id: 2, input_value: 2]
  import PhoenixHTMLHelpers.Form, only: [label: 4, password_input: 3]

  alias AshAuthentication.Phoenix.Components.Password.Input
  alias AshAuthentication.Phoenix.Web
  alias AshPhoenix.Form
  alias KilnCMSWeb.AuthOverrides

  @doc "The password box: upstream's `password_field/1` plus the eye toggle."
  attr :strategy, :any, required: true
  attr :form, :any, required: true
  attr :overrides, :list, default: [AshAuthentication.Phoenix.Overrides.Default]
  attr :gettext_fn, :any, default: nil
  attr :reveal, :boolean, default: true

  def password_field(assigns) do
    assigns
    |> assign(:field, assigns.strategy.password_field)
    |> assign(:label_key, :password_input_label)
    |> field()
  end

  @doc "The confirmation box: upstream's `password_confirmation_field/1` plus the eye toggle."
  attr :strategy, :any, required: true
  attr :form, :any, required: true
  attr :overrides, :list, default: [AshAuthentication.Phoenix.Overrides.Default]
  attr :gettext_fn, :any, default: nil
  attr :reveal, :boolean, default: true

  def password_confirmation_field(assigns) do
    assigns
    |> assign(:field, assigns.strategy.password_confirmation_field)
    |> assign(:label_key, :password_confirmation_input_label)
    |> field()
  end

  defp field(assigns) do
    assigns =
      assign(assigns,
        input_class: input_class(assigns),
        debounce: setting(assigns, :input_debounce)
      )

    ~H"""
    <div class={setting(assigns, :field_class)}>
      {label(
        @form,
        @field,
        Web.gettext_switch(@gettext_fn, setting(assigns, @label_key), []),
        class: setting(assigns, :label_class)
      )}
      <%= if @reveal do %>
        <div class="relative">
          {password_input(@form, @field,
            class: padded(@input_class),
            value: input_value(@form, @field),
            phx_debounce: @debounce
          )}
          <.password_reveal for={input_id(@form, @field)} />
        </div>
      <% else %>
        {password_input(@form, @field,
          class: @input_class,
          value: input_value(@form, @field),
          phx_debounce: @debounce
        )}
      <% end %>
      <Input.error form={@form} field={@field} overrides={@overrides} />
    </div>
    """
  end

  defp input_class(assigns) do
    if has_error?(assigns.form, assigns.field) do
      setting(assigns, :input_class_with_error)
    else
      setting(assigns, :input_class)
    end
  end

  # Room on the right for the eye button, so a long password never runs under it.
  defp padded(nil), do: "pr-10"
  defp padded(class), do: class <> " pr-10"

  defp has_error?(form, field), do: form |> Form.errors() |> Keyword.has_key?(field)

  defp setting(assigns, key), do: AuthOverrides.override_for(assigns.overrides, Input, key)
end
