defmodule KilnCMSWeb.ResetLive do
  @moduledoc """
  `AshAuthentication.Phoenix.ResetLive` joined under Kiln's live-view macro, so
  a url-less join is refused rather than rendering the default org's branding on
  a tenant host (#701). See `KilnCMSWeb.AuthLive`.
  """
  use KilnCMSWeb.AuthLive, upstream: AshAuthentication.Phoenix.ResetLive
end
