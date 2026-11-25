defmodule KilnCMS.MalformedPortableText do
  @moduledoc """
  Portable Text nodes in the malformed shapes a body can hold at rest (#2768),
  each with the text a reader should still get from it.

  Shared by the renderer tests and the stored-row delivery tests, so both
  cover the same shapes.
  """

  @doc "A well-formed paragraph to sit next to the malformed node."
  @spec neighbor() :: map()
  def neighbor do
    %{
      "_type" => "block",
      "_key" => "n0",
      "style" => "normal",
      "markDefs" => [],
      "children" => [span("Neighbor stays", [])]
    }
  end

  @doc "A text block with these `children`, plus any other keys in `extra`."
  @spec block(term(), map()) :: map()
  def block(children, extra \\ %{}) do
    Map.merge(
      %{"_type" => "block", "_key" => "b0", "style" => "normal", "markDefs" => []},
      Map.put(extra, "children", children)
    )
  end

  @doc "A span with this `text` and `marks`, whatever their types."
  @spec span(term(), term()) :: map()
  def span(text, marks), do: %{"_type" => "span", "text" => text, "marks" => marks}

  @doc """
  `{name, node, kept}` for every shape: `kept` is the text a renderer must
  keep from `node`, or nil when there is none to keep.
  """
  @spec shapes() :: [{String.t(), term(), String.t() | nil}]
  def shapes do
    [
      {"marks as a string", block([span("Bold words", "strong")]), "Bold words"},
      {"a binary child", block(["Loose child"]), "Loose child"},
      {"children as a string", block("String children"), "String children"},
      {"a nil child", block([nil]), nil},
      {"a map text", block([span(%{}, [])]), nil},
      {"a non-map markDefs entry with a span marked by it",
       block([span("Marked by x", ["x"])], %{"markDefs" => ["x"]}), "Marked by x"},
      {"a top-level binary node", "x", nil},
      {"a custom _type node with string children",
       %{"_type" => "callout", "_key" => "c0", "children" => "Custom node text"},
       "Custom node text"},
      {"a table cell with marks as a string",
       %{
         "_type" => "table",
         "_key" => "t0",
         "rows" => [%{"cells" => [%{"children" => [span("Cell words", "strong")]}]}]
       }, "Cell words"},
      {"a code block with string children",
       block("codeChildren()", %{"style" => "code", "language" => "elixir"}), "codeChildren"},
      {"a code block with string marks",
       block([span("codeMarks()", "strong")], %{"style" => "code"}), "codeMarks"},
      {"a numeric-string list level",
       block([span("Level item", [])], %{"listItem" => "bullet", "level" => "2"}), "Level item"}
    ]
  end
end
