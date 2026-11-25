defmodule Kiln.Advisory.BodyTest do
  @moduledoc """
  `Kiln.Advisory.Body`'s link helpers read a stored Portable Text node as
  they find it, so a malformed one reads as empty text rather than raising
  (kiln_cms#2768).
  """
  use ExUnit.Case, async: true

  alias Kiln.Advisory.Body

  @link %{"_key" => "lk", "_type" => "link", "href" => "/about"}

  test "pairs each link with the text of the spans it marks" do
    node = %{
      "markDefs" => [@link],
      "children" => [
        %{"text" => "Read ", "marks" => []},
        %{"text" => "about us", "marks" => ["lk"]}
      ]
    }

    assert Body.node_links(node, 2) == [%{text: "about us", href: "/about", index: 2}]
  end

  # Fails on the code before kiln_cms#2768: `to_string/1` on a map raised.
  test "a map or list text reads as no text" do
    node = %{
      "markDefs" => [@link],
      "children" => [
        %{"text" => %{"x" => 1}, "marks" => ["lk"]},
        %{"text" => ["y"], "marks" => ["lk"]},
        %{"text" => "kept", "marks" => ["lk"]}
      ]
    }

    assert Body.node_links(node, 0) == [%{text: "kept", href: "/about", index: 0}]
  end

  test "binary or numeric children read as no anchor text; a lone map as its span" do
    for children <- ["abc", 1, [nil, "abc"]] do
      node = %{"markDefs" => [@link], "children" => children}
      assert Body.node_links(node, 0) == [%{text: "", href: "/about", index: 0}]
    end

    node = %{"markDefs" => [@link], "children" => %{"text" => "x", "marks" => ["lk"]}}
    assert Body.node_links(node, 0) == [%{text: "x", href: "/about", index: 0}]
  end

  # Fails on the code before kiln_cms#2768: `to_string/1` on a map raised.
  test "a link whose href is not a string reads as an empty href" do
    node = %{"markDefs" => [%{@link | "href" => %{}}], "children" => []}

    assert Body.node_hrefs(node) == [""]
    assert [%{href: ""}] = Body.node_links(node, 0)
  end

  test "the same holds inside table cells" do
    table = %{
      "_type" => "table",
      "rows" => [
        %{
          "cells" => [
            %{"markDefs" => [@link], "children" => [%{"text" => %{}, "marks" => ["lk"]}]}
          ]
        }
      ]
    }

    assert Body.node_links(table, 1) == [%{text: "", href: "/about", index: 1}]
  end
end
