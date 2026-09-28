defmodule KilnCMSWeb.TwoFactorHTML do
  @moduledoc """
  The second-factor prompt at `/sign-in/verify` (`KilnCMSWeb.TwoFactorController`).

  A template in `Layouts.auth/1` rather than the standalone HTML string it used
  to be (#1676). That page was dark-only with hard-coded colours, gave its code
  field no label, and declared `lang="en"` over translated copy. Rendered here
  it takes the root layout's `lang` (the request's Gettext locale), the site's
  white-label brand row and the ember tokens in both themes — and it is drawn
  with the same kit classes `KilnCMSWeb.AuthOverrides` gives the library's
  sign-in pages, so the two steps of one sign-in look like one flow.

  Still no script of its own: the form is a plain POST, and the recovery-code
  entry is a `<details>` disclosure, so the page works with JavaScript off and
  adds nothing to the browser CSP.

  Two inputs rather than one because the two factors want different keyboards.
  A TOTP code is six digits (`inputmode="numeric"`, `autocomplete="one-time-code"`
  so the platform can offer it from an SMS or a password manager); a recovery
  code is base32 letters, which a numeric keypad on a phone cannot type. Both
  post the same `code` field to the same action, so the controller and its
  budget are unchanged.
  """
  use KilnCMSWeb, :html

  embed_templates "two_factor_html/*"

  @doc false
  # An `aria-describedby` from the ids that apply — `false`/`nil` entries are
  # the ones that do not (the error line is only there after a refusal).
  @spec described_by([String.t() | false | nil]) :: String.t()
  def described_by(ids), do: ids |> Enum.filter(&is_binary/1) |> Enum.join(" ")
end
