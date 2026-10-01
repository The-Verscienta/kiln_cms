defmodule KilnCMSWeb.ConnectionNoticeTest do
  @moduledoc """
  The two connection notices in `Layouts.flash_group/1` (#1784, #1821).

  They arrive hidden and are raised only by `assets/js/connection_notice.js`,
  once the view has been in trouble for a few seconds — so the markup must not
  carry LiveView's own `phx-disconnected` command, which would raise them after
  half a second, and each must carry the "Try again" button the module runs.
  The timing and the button's effect are browser behaviour, covered in
  `e2e/tests/reconnect_toasts.spec.js`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias KilnCMSWeb.Layouts

  defp render_group do
    %{__changed__: %{}, flash: %{}}
    |> Layouts.flash_group()
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  for {id, title} <- [
        {"client-error", "We can't find the internet"},
        {"server-error", "Something went wrong!"}
      ] do
    test "##{id} arrives hidden, as an alert, with a Try again button" do
      notice = LazyHTML.query(render_group(), "##{unquote(id)}")

      assert LazyHTML.attribute(notice, "hidden") == [""]
      assert LazyHTML.attribute(notice, "role") == ["alert"]
      assert LazyHTML.text(notice) =~ unquote(title)

      button = LazyHTML.query(notice, "button[data-connection-retry]")
      assert LazyHTML.attribute(button, "type") == ["button"]
      assert LazyHTML.text(button) =~ "Try again"
    end

    test "##{id} is not raised by LiveView's half-second disconnect command" do
      notice = LazyHTML.query(render_group(), "##{unquote(id)}")

      assert LazyHTML.attribute(notice, "id") == [unquote(id)]
      assert LazyHTML.attribute(notice, "phx-disconnected") == []
      assert LazyHTML.attribute(notice, "phx-connected") == []
      # A flash is dismissed by a click anywhere on it, which would swallow
      # the button's click.
      assert LazyHTML.attribute(notice, "phx-click") == []
    end
  end

  test "the notices sit inside the polite live region" do
    assert LazyHTML.attribute(LazyHTML.query(render_group(), "#flash-group"), "aria-live") ==
             ["polite"]
  end
end
