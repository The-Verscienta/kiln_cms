defmodule KilnCMS.Test.AccessibleNamesTest do
  @moduledoc """
  The helper the console's accessible-name tests stand on (#1768, #1769,
  #1774). Each rule is pinned here so a helper that quietly answered "" or
  ignored `aria-hidden` could not leave those tests green by agreeing with a
  broken page.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Test.AccessibleNames

  test "aria-label wins over the visible text" do
    html = ~s(<button id="b" aria-label="Edit Adaptogen">Edit</button>)
    assert AccessibleNames.name(html, "#b") == "Edit Adaptogen"
  end

  test "a control takes the text of the label pointing at it" do
    html = ~s(<label for="t">Type</label><select id="t"><option>All types</option></select>)
    assert AccessibleNames.name(html, "#t") == "Type"
  end

  test "without either, the text counts, aria-hidden parts do not, whitespace collapses" do
    html = ~s(<button id="b"><span aria-hidden="true">+</span>  missing
      <span class="sr-only">for About</span></button>)

    assert AccessibleNames.name(html, "#b") == "missing for About"
  end

  test "an element with nothing to say is nameless" do
    assert AccessibleNames.name(
             ~s(<button id="b"><span aria-hidden="true">x</span></button>),
             "#b"
           ) ==
             nil
  end

  test "repeated/2 reports each name shared by more than one match" do
    html = """
    <button>Edit</button><button>Edit</button>
    <button aria-label="Delete A">x</button><button aria-label="Delete B">x</button>
    """

    assert AccessibleNames.repeated(html, "button") == ["Edit"]
    assert AccessibleNames.repeated(html, "button[aria-label]") == []
  end

  test "name/2 refuses a selector that does not pick exactly one element" do
    assert_raise ArgumentError, fn -> AccessibleNames.name("<a>x</a><a>y</a>", "a") end
    assert_raise ArgumentError, fn -> AccessibleNames.name("<a>x</a>", "button") end
  end
end
