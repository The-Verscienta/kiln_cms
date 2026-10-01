defmodule KilnCMSWeb.CoreComponentsTest do
  @moduledoc """
  Regression for #172: form inputs link their validation errors to the field via
  aria-invalid + aria-describedby so screen readers announce which field failed.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import KilnCMSWeb.CoreComponents

  defp render_input(assigns),
    do: render_component(&input/1, Map.merge(%{name: "user[email]", value: ""}, assigns))

  test "an input with errors is aria-invalid and points at its error container" do
    html =
      render_input(%{type: "text", id: "user_email", label: "Email", errors: ["can't be blank"]})

    assert html =~ ~s(aria-invalid="true")
    assert html =~ ~s(aria-describedby="user_email-error")
    assert html =~ ~s(id="user_email-error")
    assert html =~ "can&#39;t be blank"
  end

  test "an input without errors omits the aria error attributes" do
    html = render_input(%{type: "text", id: "user_email", label: "Email", errors: []})

    refute html =~ "aria-invalid"
    refute html =~ "aria-describedby"
  end

  for type <- ~w(select textarea) do
    test "a #{type} with errors is aria-invalid and described by its errors" do
      html =
        render_input(%{
          type: unquote(type),
          id: "f_#{unquote(type)}",
          label: "F",
          errors: ["is invalid"],
          options: [{"A", "a"}]
        })

      assert html =~ ~s(aria-invalid="true")
      assert html =~ ~s(aria-describedby="f_#{unquote(type)}-error")
    end
  end

  describe "button/1" do
    defp render_button(assigns),
      do:
        render_component(
          &button/1,
          Map.merge(%{inner_block: [%{inner_block: fn _, _ -> "Go" end}]}, assigns)
        )

    defp classes(html) do
      [_, class] = Regex.run(~r/class="([^"]*)"/, html)
      String.split(class)
    end

    test "a caller's class adds to the button classes instead of replacing them" do
      html = render_button(%{variant: "primary", size: "sm", class: "mt-4 self-start"})

      assert Enum.sort(classes(html)) == Enum.sort(~w(btn btn-primary btn-sm mt-4 self-start))
    end

    test "without a class it renders just the button classes" do
      assert classes(render_button(%{})) == ~w(btn btn-default)
    end
  end

  # #1839: the health pill's meaning lived in a `title`, which a screen reader
  # and a keyboard never reach, and "Due soon" without a date had none at all.
  describe "health_badge/1" do
    test "explains itself in a tooltip and to a screen reader" do
      html = render_component(&health_badge/1, health: :due_soon)

      assert html =~ "Due soon"
      assert html =~ ~s(title="Its review date is coming up.")
      assert html =~ ~s(<span class="sr-only">Its review date is coming up.</span>)
    end

    test "adds the review date when it has one" do
      html = render_component(&health_badge/1, health: :overdue, due_at: ~U[2026-09-01 00:00:00Z])

      assert html =~
               "Its review date passed over a week ago: check it now. Review date: 2026-09-01."
    end

    test "renders nothing for fresh content" do
      assert render_component(&health_badge/1, health: :fresh) =~ ~r/^\s*$/
    end
  end
end
