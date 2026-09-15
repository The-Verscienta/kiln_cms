defmodule KilnCMSWeb.FlashAutoDismissTest do
  @moduledoc """
  Info flashes close themselves; errors wait to be closed.

  The timer, the hover/focus pause and the reduced-motion branch live in
  `assets/js/flash_auto_dismiss.js`. What the server owns is which flashes get
  the hook — and that the click-to-close stays on the element, since the timed
  close runs that same `phx-click`.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias KilnCMSWeb.CoreComponents

  test "an info flash carries the auto-dismiss hook and keeps click-to-close" do
    html = render_component(&CoreComponents.flash/1, kind: :info, flash: %{"info" => "Signed in"})

    assert html =~ ~s(phx-hook="FlashAutoDismiss")
    assert html =~ "lv:clear-flash"
  end

  test "an error flash does not dismiss itself" do
    html =
      render_component(&CoreComponents.flash/1, kind: :error, flash: %{"error" => "It broke"})

    assert html =~ "It broke"
    refute html =~ "FlashAutoDismiss"
    assert html =~ "lv:clear-flash"
  end
end
