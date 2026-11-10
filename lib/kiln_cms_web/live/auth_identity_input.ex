defmodule KilnCMSWeb.AuthIdentityInput do
  @moduledoc """
  The email box on the sign-in, register and reset-request forms, with an
  `autocomplete` attribute (#2162).

  This is `AshAuthentication.Phoenix.Components.Password.Input.identity_field/1`,
  copied, with one addition: `autocomplete="email"`. Upstream builds the
  `<input>` with a fixed option list and offers no way to add an attribute, so
  a password manager or browser autofill has nothing to go on but its guess
  from the field's name (WCAG 1.3.5, Identify Input Purpose).

  Every setting is read under upstream's name through
  `KilnCMSWeb.AuthOverrides.override_for/4`, so the `override
  Components.Password.Input` block keeps styling it. `KilnCMSWeb.AuthOverridesTest`
  renders the sign-in, register and `/reset` request forms that use this
  against upstream's and asserts they differ by nothing but this attribute, so
  an upstream change to the field fails that test rather than going stale here.

  The sibling for the password boxes is `KilnCMSWeb.AuthPasswordInput`.
  """
  use Phoenix.Component

  import PhoenixHTMLHelpers.Form, only: [label: 4, text_input: 3]

  alias AshAuthentication.Phoenix.Components.Password.Input
  alias AshAuthentication.Phoenix.Web
  alias AshPhoenix.Form
  alias KilnCMSWeb.AuthOverrides

  @doc "The identity box: upstream's `identity_field/1` plus `autocomplete=\"email\"`."
  attr :strategy, :any, required: true
  attr :form, :any, required: true
  attr :overrides, :list, default: [AshAuthentication.Phoenix.Overrides.Default]
  attr :gettext_fn, :any, default: nil

  def identity_field(assigns) do
    identity_field = assigns.strategy.identity_field

    assigns =
      assigns
      |> assign(:identity_field, identity_field)
      |> assign(:input_type, input_type(identity_field))
      |> assign(:input_class, input_class(assigns, identity_field))

    ~H"""
    <div class={setting(assigns, :field_class)}>
      {label(
        @form,
        @identity_field,
        Web.gettext_switch(@gettext_fn, setting(assigns, :identity_input_label), []),
        class: setting(assigns, :label_class)
      )}
      {text_input(@form, @identity_field,
        type: to_string(@input_type),
        class: @input_class,
        phx_debounce: setting(assigns, :input_debounce),
        autofocus: "true",
        autocomplete: "email",
        placeholder: setting(assigns, :identity_input_placeholder)
      )}
      <Input.error form={@form} field={@identity_field} overrides={@overrides} />
    </div>
    """
  end

  defp input_type(identity_field) do
    if identity_field |> to_string() |> String.contains?("email"), do: :email, else: :text
  end

  defp input_class(assigns, identity_field) do
    if assigns.form |> Form.errors() |> Keyword.has_key?(identity_field) do
      setting(assigns, :input_class_with_error)
    else
      setting(assigns, :input_class)
    end
  end

  defp setting(assigns, key), do: AuthOverrides.override_for(assigns.overrides, Input, key)
end
