defmodule KilnCMS.Test.AccessibleNames do
  @moduledoc """
  A small approximation of the accessible-name computation, for asserting what
  a screen reader or voice-control user hears a console control called
  (#1768, #1769, #1774).

  It covers the shapes the console uses, in the order the spec applies them:

    1. `aria-label`;
    2. for a form control with an `id`, the text of the `<label for=…>`
       pointing at it;
    3. otherwise the element's own text, with `aria-hidden` subtrees removed
       (so an `sr-only` suffix counts and a decorative `&rarr;` does not).

  Whitespace is collapsed. There is no `aria-labelledby`, no `title` fallback
  and no embedded-control rule — a control that relies on one of those gets
  no name here, which is the conservative answer for a test.
  """

  @doc "The accessible name of the one element `selector` matches in `html`."
  @spec name(String.t(), String.t()) :: String.t() | nil
  def name(html, selector) do
    case names(html, selector) do
      [name] -> name
      other -> raise ArgumentError, "#{inspect(selector)} matched #{length(other)} elements"
    end
  end

  @doc "The accessible name of every element `selector` matches, in order."
  @spec names(String.t(), String.t()) :: [String.t() | nil]
  def names(html, selector) do
    doc = LazyHTML.from_document(html)

    doc
    |> LazyHTML.query(selector)
    |> Enum.map(&compute(doc, &1))
  end

  @doc """
  Every accessible name that more than one element `selector` matches shares —
  the defect #1774 describes, where five buttons are all called "Edit".
  An empty list means every match is distinguishable by name alone.
  """
  @spec repeated(String.t(), String.t()) :: [String.t() | nil]
  def repeated(html, selector) do
    html
    |> names(selector)
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp compute(doc, node) do
    with nil <- present(LazyHTML.attribute(node, "aria-label")),
         nil <- label_for(doc, node) do
      node |> LazyHTML.to_tree() |> visible_text() |> present()
    end
  end

  defp label_for(doc, node) do
    case LazyHTML.attribute(node, "id") do
      [id] when id != "" ->
        doc
        |> LazyHTML.query(~s(label[for="#{id}"]))
        |> LazyHTML.to_tree()
        |> visible_text()
        |> present()

      _none ->
        nil
    end
  end

  defp visible_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, &visible_text/1)
  defp visible_text(text) when is_binary(text), do: text
  defp visible_text({:comment, _}), do: ""

  defp visible_text({_tag, attrs, children}) do
    if List.keyfind(attrs, "aria-hidden", 0) == {"aria-hidden", "true"},
      do: "",
      else: visible_text(children)
  end

  defp present([value]), do: present(value)
  defp present([]), do: nil

  defp present(value) when is_binary(value) do
    case value |> String.split() |> Enum.join(" ") do
      "" -> nil
      name -> name
    end
  end
end
