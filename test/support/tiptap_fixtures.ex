defmodule KilnCMS.TipTapFixtures do
  @moduledoc """
  Compact constructors for TipTap document fixtures in tests — deep map
  literals for nested docs format differently across Elixir versions, so
  fixtures build through these one-liners instead.
  """

  def doc(content), do: %{"type" => "doc", "content" => List.wrap(content)}

  def tt_node(type, content \\ nil)
  def tt_node(type, nil), do: %{"type" => type}
  def tt_node(type, content), do: %{"type" => type, "content" => List.wrap(content)}

  def para(text) when is_binary(text), do: tt_node("paragraph", [text(text)])
  def para(content), do: tt_node("paragraph", content)

  def text(value, marks \\ nil)
  def text(value, nil), do: %{"type" => "text", "text" => value}
  def text(value, marks), do: %{"type" => "text", "text" => value, "marks" => marks}

  def bullet_list(items), do: tt_node("bulletList", items)
  def ordered_list(items), do: tt_node("orderedList", items)
  def list_item(content), do: tt_node("listItem", List.wrap(content))
end
