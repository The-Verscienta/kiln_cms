defmodule KilnCMSWeb.SignOutLive do
  @moduledoc """
  `AshAuthentication.Phoenix.SignOutLive` joined under Kiln's live-view macro, so
  a url-less join is refused rather than rendering the default org's branding on
  a tenant host (#701). See `KilnCMSWeb.AuthLive`.

  `sign_out_route/3` emits **two** routes for `/sign-out`: a `DELETE` to the auth
  controller, and a `live` route inside a `live_session`. Only the first is
  obvious from the router, which is why this view was nearly left out — but the
  second has a signed session blob like any other and is joinable at the
  channel.
  """
  use KilnCMSWeb.AuthLive, upstream: AshAuthentication.Phoenix.SignOutLive
end
