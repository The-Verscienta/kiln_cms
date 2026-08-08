defmodule KilnCMSWeb.ModalTest do
  @moduledoc """
  `KilnCMSWeb.CoreComponents.modal/1` — the one modal shell (#693).

  Five hand-rolled copies used to carry the same seven accessibility invariants
  each, and had already drifted on `z-50` vs `z-40`, `bg-black/20` vs
  `bg-black/40`, and five different close-event names. Drift in a decorative
  class is cosmetic; drift in `aria-labelledby` is a dialog a screen reader
  cannot announce, and nothing renders differently when that happens — so the
  invariants are asserted here once, on the primitive, rather than five times on
  its callers.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  defp render(assigns) do
    ~H"""
    <KilnCMSWeb.CoreComponents.modal id={@id} on_close={@on_close} variant={@variant}>
      <:title>Pick a thing</:title>
      <p>body</p>
    </KilnCMSWeb.CoreComponents.modal>
    """
    |> rendered_to_string()
  end

  defp dialog(opts \\ []) do
    render(%{
      id: Keyword.get(opts, :id, "thing-dialog"),
      on_close: Keyword.get(opts, :on_close, "close_thing"),
      variant: Keyword.get(opts, :variant, :dialog),
      __changed__: nil
    })
  end

  describe "the accessibility invariants" do
    test "every one of the seven is present" do
      html = dialog()

      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(tabindex="-1")
      assert html =~ ~s(phx-hook="FocusTrap")
      assert html =~ ~s(aria-hidden="true")
      assert html =~ ~s(data-close-event="close_thing")
      assert html =~ ~s(aria-label="Close")
    end

    # The label id is DERIVED from the dialog id rather than passed separately,
    # which is the drift that has no visible symptom: an `aria-labelledby`
    # pointing at nothing renders exactly like one that works, and only a screen
    # reader ever finds out.
    test "the title id is derived from the dialog id" do
      html = dialog(id: "compare-dialog")

      assert html =~ ~s(aria-labelledby="compare-dialog-title")
      assert html =~ ~s(id="compare-dialog-title")
    end

    # One event name, reaching all three ways out — each asserted where it has to
    # BE, not merely counted. A `String.split |> length` check here passed with
    # `phx-click` deleted from the ✕ entirely: the count survives any refactor
    # that preserves the number of occurrences, and it only worked at all because
    # the chosen event name was not a substring of the surrounding markup (the
    # real media drawer uses `"close"`, which occurs inside `data-close-event`).
    test "Escape, the scrim and the close button all push the same event" do
      doc = Floki.parse_fragment!(dialog(on_close: "close_compare"))

      # Escape, via the FocusTrap hook.
      assert [_] = Floki.find(doc, ~s([role="dialog"][data-close-event="close_compare"]))

      # Clicking beside the dialog.
      assert [_] = Floki.find(doc, ~s([aria-hidden="true"][phx-click="close_compare"]))

      # The ✕.
      assert [_] = Floki.find(doc, ~s(button[aria-label="Close"][phx-click="close_compare"]))
    end
  end

  # The concrete consequence #693 was filed for. The image picker and the
  # compare modal were both `z-50` with WINDOW-level Escape bindings, so with
  # both open one Escape press dispatched two close events while two focus traps
  # fought over focus.
  #
  # Binding on the panel makes nesting well-defined: `FocusTrap` moves focus
  # inside on mount and keeps it there, keydown bubbles from whatever descendant
  # holds focus, and so the innermost open dialog is the one that closes — which
  # is what a person pressing Escape means.
  # It is `data-close-event` rather than `phx-keydown` because LiveView's key
  # binding reads the attribute off the EXACT event target and does not walk
  # ancestors — `bind()` in phoenix_live_view.esm.js does
  # `e.target.getAttribute(binding)`. `FocusTrap` has just moved focus to a
  # button inside the panel, so a `phx-keydown` there never fires at all. That
  # was caught in the browser, not by a test, which is why this one names the
  # mechanism rather than just the attribute.
  test "Escape is scoped to the dialog, not the window" do
    html = dialog()

    refute html =~ "phx-window-keydown"
    refute html =~ "phx-keydown"
    assert html =~ ~s(data-close-event="close_thing")
    assert html =~ ~s(phx-hook="FocusTrap")
  end

  describe "variants" do
    # A drawer sits BESIDE the page rather than over it, so its scrim only dims
    # — the editor stays readable while you pick from the library next to it.
    # That was the one difference among the five copies that meant something;
    # the rest was drift.
    test "a drawer dims more lightly than a centred dialog" do
      assert dialog(variant: :drawer) =~ "bg-black/20"
      assert dialog(variant: :dialog) =~ "bg-black/40"
    end

    test "a drawer is full-height on the right; a dialog is centred" do
      drawer = dialog(variant: :drawer)
      assert drawer =~ "inset-y-0"
      assert drawer =~ "right-0"

      assert dialog(variant: :dialog) =~ "mx-auto"
    end

    # Both were `z-50` and `z-40` before, so one could open *behind* the other.
    test "both sit on the same layer" do
      assert dialog(variant: :drawer) =~ "z-50"
      assert dialog(variant: :dialog) =~ "z-50"
    end
  end
end
