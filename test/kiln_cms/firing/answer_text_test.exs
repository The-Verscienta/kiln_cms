defmodule KilnCMS.Firing.AnswerTextTest do
  @moduledoc """
  The walk behind the `:llm` and `:json_ld` opt-in (`deliver_llm`, #2282):
  hand-built definitions and values, so each rule is one assertion — what is
  included, what is skipped, and how both surfaces render it.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Firing.AnswerText

  defp field(name, type, attrs \\ %{}) do
    Map.merge(
      %{
        name: name,
        label: String.capitalize(name),
        field_type: type,
        format: :rich,
        position: 0,
        item_setting: false,
        private: false,
        deliver_llm: false,
        content_type: :post,
        link_of_id: nil,
        group_of_id: nil,
        flex_of_id: nil,
        item_types: [],
        group_fields: []
      },
      attrs
    )
  end

  defp flagged(name, type, attrs \\ %{}),
    do: field(name, type, Map.put(attrs, :deliver_llm, true))

  defp custom(definitions, values), do: %{definitions: definitions, values: values}

  # faq (flexible) > qa item type (question, answer, mood setting)
  defp faq do
    qa =
      field("qa", :group, %{
        label: "Question and answer",
        flex_of_id: "faq",
        content_type: nil,
        group_fields: [
          field("answer", :text, %{label: "Answer", position: 1, group_of_id: "qa"}),
          field("question", :string, %{label: "Question", group_of_id: "qa"}),
          field("mood", :string, %{item_setting: true, position: 2, group_of_id: "qa"}),
          field("votes", :integer, %{position: 3, group_of_id: "qa"})
        ]
      })

    flagged("faq", :flexible, %{label: "FAQ", item_types: [qa]})
  end

  defp qa_item(question, answer),
    do: %{"_id" => "x", "_type" => "qa", "question" => question, "answer" => answer, "votes" => 3}

  describe "entries/1" do
    test "a flag off, or no custom fields, contributes nothing" do
      assert AnswerText.entries(nil) == []
      assert AnswerText.entries(custom([], %{})) == []
      assert AnswerText.entries(custom([field("note", :string)], %{"note" => "x"})) == []
    end

    test "a flagged string and a flagged rich text field give plain paragraphs" do
      defs = [
        flagged("note", :string, %{label: "Note"}),
        flagged("body", :text, %{label: "Body", position: 1})
      ]

      values = %{"note" => "  Short note ", "body" => "<p>One &amp; two.</p><p>Three.</p>"}

      assert [
               %{label: "Note", kind: :text, parts: [{:text, "Note", "Short note"}]},
               %{label: "Body", kind: :text, parts: [{:text, "Body", body}]}
             ] = AnswerText.entries(custom(defs, values))

      assert body == "One & two.\n\nThree."
    end

    test "fields come out in position order, and a plain text field is kept as typed" do
      defs = [
        flagged("b", :text, %{label: "B", position: 2, format: :plain}),
        flagged("a", :string, %{label: "A", position: 1})
      ]

      values = %{"a" => "first", "b" => "a <b> c"}

      assert [%{label: "A"}, %{label: "B", parts: [{:text, "B", "a <b> c"}]}] =
               AnswerText.entries(custom(defs, values))
    end

    test "a group gives one text line per text sub-field, in order, numbers skipped" do
      group =
        flagged("dosage", :group, %{
          label: "Dosage",
          group_fields: [
            field("unit", :string, %{label: "Unit", position: 1, group_of_id: "d"}),
            field("form", :string, %{label: "Form", group_of_id: "d"}),
            field("amount", :float, %{label: "Amount", position: 2, group_of_id: "d"})
          ]
        })

      values = %{"dosage" => %{"form" => "Tea", "unit" => "cup", "amount" => 2.5}}

      assert [%{kind: :group, parts: [{:text, "Form", "Tea"}, {:text, "Unit", "cup"}]}] =
               AnswerText.entries(custom([group], values))
    end

    test "a repeating group contributes every row" do
      group =
        flagged("steps", :group, %{
          label: "Steps",
          group_fields: [field("do", :string, %{label: "Do", group_of_id: "s"})]
        })

      values = %{"steps" => [%{"do" => "Boil"}, %{"do" => "Steep"}]}

      assert [%{parts: [{:text, "Do", "Boil"}, {:text, "Do", "Steep"}]}] =
               AnswerText.entries(custom([group], values))
    end

    test "a flexible field gives one item per stored item, item_setting and numbers skipped" do
      values = %{"faq" => [qa_item("Why?", "<p>Because.</p>"), qa_item("Who?", "Me")]}

      assert [%{kind: :flexible, label: "FAQ", parts: parts}] =
               AnswerText.entries(custom([faq()], values))

      assert [
               {:item,
                %{
                  label: "Question and answer",
                  parts: [{:text, "Question", "Why?"}, {:text, "Answer", "Because."}]
                }},
               {:item, %{parts: [{:text, "Question", "Who?"}, {:text, "Answer", "Me"}]}}
             ] = parts
    end

    test "an item of an unknown type, and a key no definition names, are ignored" do
      item = qa_item("Q", "A") |> Map.put("secret", "never printed")

      values = %{"faq" => [%{"_type" => "ghost", "question" => "raw"}, item]}
      [%{parts: parts}] = AnswerText.entries(custom([faq()], values))

      assert length(parts) == 1
      refute inspect(parts) =~ "never printed"
      refute inspect(parts) =~ "raw"
    end

    test "empty values, and a field with no text at all, contribute nothing" do
      defs = [flagged("note", :string), faq()]
      values = %{"note" => "   ", "faq" => [qa_item("", ""), %{"_type" => "qa", "votes" => 1}]}

      assert AnswerText.entries(custom(defs, values)) == []
    end

    test "an item keeps its other text when one value is blank" do
      values = %{"faq" => [qa_item("", "Only an answer")]}

      assert [%{parts: [{:item, %{parts: [{:text, "Answer", "Only an answer"}]}}]}] =
               AnswerText.entries(custom([faq()], values))
    end

    test "three levels of flexible nesting are walked, and no deeper" do
      cell = field("cell", :group, %{flex_of_id: "cells", group_fields: [field("text", :string)]})
      cells = field("cells", :flexible, %{group_of_id: "row", position: 1, item_types: [cell]})

      row =
        field("row", :group, %{
          flex_of_id: "rows",
          group_fields: [field("name", :string, %{label: "Name"}), cells]
        })

      rows = field("rows", :flexible, %{group_of_id: "section", position: 1, item_types: [row]})

      section =
        field("section", :group, %{
          flex_of_id: "sections",
          group_fields: [field("title", :string, %{label: "Title"}), rows]
        })

      sections = flagged("sections", :flexible, %{label: "Sections", item_types: [section]})

      values = %{
        "sections" => [
          %{
            "_type" => "section",
            "title" => "S",
            "rows" => [
              %{"_type" => "row", "name" => "R", "cells" => [%{"_type" => "cell", "text" => "C"}]}
            ]
          }
        ]
      }

      assert [%{parts: [{:item, section_item}]}] = AnswerText.entries(custom([sections], values))
      assert [{:text, "Title", "S"}, {:item, row_item}] = section_item.parts
      assert [{:text, "Name", "R"}, {:item, cell_item}] = row_item.parts
      assert [{:text, "Text", "C"}] = cell_item.parts

      # A level past the cap (a hand-seeded definition tree) is not entered.
      deep_cell = %{
        cell
        | group_fields: [field("kids", :flexible, %{position: 1, item_types: [row]})]
      }

      deep_cells = %{cells | item_types: [deep_cell]}
      deep_row = %{row | group_fields: [deep_cells]}
      deep_rows = %{rows | item_types: [deep_row]}
      deep_section = %{section | group_fields: [deep_rows]}
      deep = flagged("deep", :flexible, %{item_types: [deep_section]})

      deep_values = %{
        "deep" => [
          %{
            "_type" => "section",
            "rows" => [
              %{
                "_type" => "row",
                "cells" => [
                  %{"_type" => "cell", "kids" => [%{"_type" => "row", "name" => "too deep"}]}
                ]
              }
            ]
          }
        ]
      }

      assert AnswerText.entries(custom([deep], deep_values)) == []
    end

    test "private, nested and wrong-typed flagged rows are not fields of the document" do
      defs = [
        flagged("hidden", :string, %{private: true}),
        flagged("inner", :string, %{group_of_id: "g"}),
        flagged("item", :group, %{flex_of_id: "f"}),
        flagged("count", :integer),
        flagged("ok", :string)
      ]

      values = Map.new(~w(hidden inner item count ok), &{&1, "text"}) |> Map.put("count", 4)

      assert [%{label: "Ok"}] = AnswerText.entries(custom(defs, values))
    end

    test "a value of the wrong shape is skipped, not raised on" do
      group = flagged("g", :group, %{group_fields: [field("x", :string, %{group_of_id: "g"})]})
      defs = [flagged("note", :string), group, faq()]
      values = %{"note" => %{"a" => 1}, "g" => "scalar", "faq" => "scalar"}

      assert AnswerText.entries(custom(defs, values)) == []
    end
  end

  describe "markdown/1" do
    test "a text field is a ## section; a group and items are labelled lines" do
      group =
        flagged("dosage", :group, %{
          label: "Dosage",
          position: 1,
          group_fields: [field("unit", :string, %{label: "Unit", group_of_id: "d"})]
        })

      defs = [flagged("note", :string, %{label: "Note"}), group, faq() |> Map.put(:position, 2)]

      values = %{
        "note" => "Hi",
        "dosage" => %{"unit" => "cup"},
        "faq" => [qa_item("Why?", "Because.")]
      }

      assert defs |> custom(values) |> AnswerText.entries() |> AnswerText.markdown() == [
               "## Note\n\nHi",
               "## Dosage\n\n**Unit:** cup",
               "## FAQ\n\n### Question and answer\n\n**Question:** Why?\n\n**Answer:** Because."
             ]
    end

    test "nested items take deeper headings" do
      inner = field("inner", :group, %{flex_of_id: "kids", group_fields: [field("t", :string)]})
      kids = field("kids", :flexible, %{group_of_id: "outer", position: 1, item_types: [inner]})

      outer =
        field("outer", :group, %{
          flex_of_id: "top",
          group_fields: [field("n", :string, %{label: "N"}), kids]
        })

      top = flagged("top", :flexible, %{label: "Top", item_types: [outer]})

      values = %{
        "top" => [
          %{"_type" => "outer", "n" => "a", "kids" => [%{"_type" => "inner", "t" => "b"}]}
        ]
      }

      [md] = [top] |> custom(values) |> AnswerText.entries() |> AnswerText.markdown()
      assert md == "## Top\n\n### Outer\n\n**N:** a\n\n#### Inner\n\n**T:** b"
    end
  end

  describe "web_page_elements/1" do
    test "a field is one element, an item one element, nested items flattened into it" do
      defs = [flagged("note", :string, %{label: "Note"}), faq() |> Map.put(:position, 1)]
      values = %{"note" => "Hi", "faq" => [qa_item("Why?", "Because."), qa_item("Who?", "Me")]}

      assert defs |> custom(values) |> AnswerText.entries() |> AnswerText.web_page_elements() == [
               %{"@type" => "WebPageElement", "name" => "Note", "text" => "Hi"},
               %{
                 "@type" => "WebPageElement",
                 "name" => "Question and answer",
                 "text" => "Why?\n\nBecause."
               },
               %{
                 "@type" => "WebPageElement",
                 "name" => "Question and answer",
                 "text" => "Who?\n\nMe"
               }
             ]
    end
  end

  describe "caps" do
    test "elements stop at the maximum" do
      items = for n <- 1..(AnswerText.max_elements() + 10), do: qa_item("Q#{n}", "A")

      elements =
        [faq()]
        |> custom(%{"faq" => items})
        |> AnswerText.entries()
        |> AnswerText.web_page_elements()

      assert length(elements) == AnswerText.max_elements()
    end

    test "long text is cut at a word boundary with an ellipsis, in both surfaces" do
      long = String.duplicate("word ", 2_000)
      defs = [flagged("note", :string, %{label: "Note"})]
      entries = defs |> custom(%{"note" => long}) |> AnswerText.entries()

      [%{"text" => text}] = AnswerText.web_page_elements(entries)
      [section] = AnswerText.markdown(entries)
      body = String.replace_prefix(section, "## Note\n\n", "")

      for cut <- [text, body] do
        assert String.length(cut) <= AnswerText.max_chars() + 1
        assert String.ends_with?(cut, "word…")
      end
    end

    test "text at the cap is left whole" do
      text = String.duplicate("a", AnswerText.max_chars())
      entries = [flagged("n", :string)] |> custom(%{"n" => text}) |> AnswerText.entries()

      assert [%{"text" => ^text}] = AnswerText.web_page_elements(entries)
    end
  end
end
