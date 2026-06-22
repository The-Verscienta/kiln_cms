defmodule KilnCMSWeb.AuthOverrides do
  @moduledoc """
  Tailwind UI overrides for AshAuthentication Phoenix components.
  """
  use AshAuthentication.Phoenix.Overrides

  alias AshAuthentication.Phoenix.{
    Components,
    ConfirmLive,
    MagicSignInLive,
    ResetLive,
    SignInLive,
    SignOutLive
  }

  @page_root "grid min-h-screen place-items-center bg-base-100 px-4"
  @card_root "mx-auto w-full max-w-sm lg:max-w-md"
  @title "text-2xl font-semibold tracking-tight text-base-content"
  @form_btn """
  mt-4 mb-4 w-full rounded-lg bg-base-content px-4 py-2.5 text-sm font-semibold
  text-base-100 transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50
  """
  @field_label "block text-sm font-medium text-base-content mb-1"
  @input """
  w-full rounded-lg border border-base-content/20 bg-transparent px-3 py-2 text-sm
  transition focus:border-base-content/40 focus:outline-none focus:ring-2
  focus:ring-base-content/10
  """
  @input_error @input <> " border-red-500 focus:border-red-500 focus:ring-red-500/20"
  @muted "text-sm text-base-content/60"
  @link "text-sm font-medium text-base-content underline decoration-base-content/30 hover:decoration-base-content"

  override SignInLive do
    set :root_class, @page_root
  end

  override SignOutLive do
    set :root_class, @page_root
  end

  override ConfirmLive do
    set :root_class, @page_root
  end

  override ResetLive do
    set :root_class, @page_root
  end

  override MagicSignInLive do
    set :root_class, @page_root
  end

  override Components.SignIn do
    set :root_class, "w-full py-12"
    set :strategy_class, @card_root
    set :authentication_error_container_class, "text-center text-base-content"
    set :authentication_error_text_class, "text-sm text-red-600"
    set :strategy_display_order, :forms_first
  end

  override Components.SignOut do
    set :root_class, @card_root
    set :h2_class, @title <> " mt-2 mb-4"
    set :h2_text, "Sign out"
    set :info_text, "Are you sure you want to sign out?"
    set :info_text_class, @muted <> " mb-4"
    set :form_class, nil
    set :button_text, "Sign out"
    set :button_class, @form_btn
  end

  override Components.Confirm do
    set :root_class, "w-full py-12"
    set :strategy_class, @card_root
  end

  override Components.Confirm.Input do
    set :submit_class, @form_btn
  end

  override Components.Reset do
    set :root_class, "w-full py-12"
    set :strategy_class, @card_root
  end

  override Components.Reset.Form do
    set :root_class, nil
    set :label_class, @title <> " mt-2 mb-4"
    set :form_class, nil
    set :spacer_class, "py-1"
    set :button_text, "Change password"
    set :disable_button_text, "Changing password ..."
  end

  override Components.Banner do
    set :root_class, "mb-6 flex w-full justify-center"
    set :href_class, nil
    set :href_url, "/"
    set :image_class, "h-10 w-auto"
    set :dark_image_class, "h-10 w-auto"
    set :image_url, "/images/logo.svg"
    set :dark_image_url, "/images/logo.svg"
    set :text_class, "ml-3 text-lg font-semibold tracking-tight text-base-content"
    set :text, "KilnCMS"
  end

  override Components.HorizontalRule do
    set :root_class,
        "my-4 flex items-center gap-3 text-xs uppercase tracking-wide text-base-content/50"

    set :hr_outer_class, "flex-1 border-t border-base-content/15"
    set :hr_inner_class, nil
    set :text_outer_class, nil
    set :text_inner_class, nil
    set :text, "or"
  end

  override Components.Flash do
    set :message_class_info, """
    fixed top-4 right-4 z-50 w-80 max-w-[calc(100vw-2rem)] rounded-lg border
    border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-900 shadow-sm
    """

    set :message_class_error, """
    fixed top-4 right-4 z-50 w-80 max-w-[calc(100vw-2rem)] rounded-lg border
    border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-900 shadow-sm
    """
  end

  override Components.MagicLink do
    set :root_class, "mt-4 mb-4"
    set :label_class, @title <> " mt-2 mb-4"
    set :form_class, nil

    set :request_flash_text,
        "If this user exists in our database, you will be contacted with a sign-in link shortly."

    set :disable_button_text, "Requesting ..."
  end

  override Components.MagicLink.Input do
    set :submit_class, @form_btn
    set :submit_label, "Send magic link"
    set :input_debounce, 350
    set :remember_me_class, "mt-2 mb-2 flex items-center gap-2"
    set :remember_me_input_label, "Remember me"
    set :checkbox_class, "rounded border-base-content/30"
    set :checkbox_label_class, @muted
  end

  override Components.Password do
    set :root_class, "mt-4 mb-4"
    set :interstitial_class, "flex flex-row justify-between text-sm font-medium"
    set :toggler_class, @link <> " px-0"
    set :sign_in_toggle_text, "Already have an account?"
    set :register_toggle_text, "Need an account?"
    set :reset_toggle_text, "Forgot your password?"
    set :show_first, :sign_in
    set :hide_class, "hidden"
    set :register_form_module, AshAuthentication.Phoenix.Components.Password.RegisterForm
    set :sign_in_form_module, AshAuthentication.Phoenix.Components.Password.SignInForm
    set :reset_form_module, AshAuthentication.Phoenix.Components.Password.ResetForm
  end

  override Components.Password.SignInForm do
    set :root_class, nil
    set :label_class, @title <> " mt-2 mb-4"
    set :form_class, nil
    set :slot_class, "my-4"
    set :button_text, "Sign in"
    set :disable_button_text, "Signing in ..."
  end

  override Components.Password.RegisterForm do
    set :root_class, nil
    set :label_class, @title <> " mt-2 mb-4"
    set :form_class, nil
    set :slot_class, "my-4"
    set :button_text, "Register"
    set :disable_button_text, "Registering ..."
  end

  override Components.Password.ResetForm do
    set :root_class, nil
    set :label_class, @title <> " mt-2 mb-4"
    set :form_class, nil
    set :slot_class, "my-4"
    set :button_text, "Request reset password link"
    set :disable_button_text, "Requesting ..."

    set :reset_flash_text,
        "If this user exists in our system, you will be contacted with password reset instructions shortly."
  end

  override Components.Password.Input do
    set :field_class, "mt-2 mb-2"
    set :label_class, @field_label
    set :input_class, @input
    set :input_class_with_error, @input_error
    set :submit_class, @form_btn
    set :password_input_label, "Password"
    set :password_confirmation_input_label, "Password confirmation"
    set :identity_input_label, "Email"
    set :identity_input_placeholder, nil
    set :error_ul, "my-3 list-inside list-disc text-sm text-red-600"
    set :error_li, nil
    set :input_debounce, 350
    set :remember_me_class, "mt-2 mb-2 flex items-center gap-2"
    set :remember_me_input_label, "Remember me"
    set :checkbox_class, "rounded border-base-content/30"
    set :checkbox_label_class, @muted
  end

  override Components.OAuth2 do
    set :root_class, "mt-2 mb-4 w-full"

    set :link_class,
        @form_btn <>
          " border border-base-content/20 bg-transparent text-base-content hover:bg-base-200"

    set :icon_class, "-ml-0.5 mr-2 h-4 w-4"
    set :icon_src, nil
  end

  override Components.Apple do
    set :root_class, "mt-2 mb-4 w-full"
    set :link_class, @form_btn <> " bg-base-content/90"
    set :icon_class, ""
  end
end
