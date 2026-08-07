defmodule KilnCMSWeb.AuthLayoutFlashTest do
  @moduledoc """
  `Layouts.auth/1` draws a flash group (#884).

  Every auth route swaps AshAuthentication's own live layout — which renders
  `Components.Flash` — for `Layouts.auth/1`, to draw the white-label banner
  (#48/#701). That swap dropped flash rendering, so a message set on `/reset` or
  the magic-link request form — their *only* success signal, via
  `send(self(), {:put_flash, …})` — landed in `@flash` but was never shown. The
  user couldn't tell a successful request from a dead button.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias KilnCMSWeb.Layouts

  # How Phoenix invokes a `layout:` — assigns carrying `:inner_content`, applied
  # directly to the layout function (see `KilnCMSWeb.BrandingFailClosedTest` for
  # why this is the faithful invocation). No `:current_org` key, so the layout
  # renders unbranded — flash rendering is independent of branding.
  defp render_auth(flash) do
    rendered_to_string(Layouts.auth(%{__changed__: %{}, inner_content: [], flash: flash}))
  end

  test "an info flash set on an auth page is rendered (the /reset + magic-link signal)" do
    msg = "If this user exists in our system, you will be contacted shortly."
    assert render_auth(%{"info" => msg}) =~ msg
  end

  test "an error flash is rendered too" do
    msg = "That link has expired."
    assert render_auth(%{"error" => msg}) =~ msg
  end

  test "no flash draws no message" do
    refute render_auth(%{}) =~ "you will be contacted"
  end
end
