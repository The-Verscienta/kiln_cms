defmodule KilnCMSWeb.SignInUnlockHTML do
  @moduledoc """
  The sign-in unlock pages (`KilnCMSWeb.SignInUnlockController`, #2250), in
  `Layouts.auth/1` with the same kit classes as `/sign-in/verify`.

  No script: both forms are plain POSTs, so the pages work with JavaScript off
  and add nothing to the browser CSP. None of them says whether an account
  exists or is paused.
  """
  use KilnCMSWeb, :html

  embed_templates "sign_in_unlock_html/*"
end
