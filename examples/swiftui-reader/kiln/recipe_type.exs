# The `recipe` type the SwiftUI reader shows: its attributes and its fields,
# in creation order. Plain data, evaluated by two readers so they cannot
# disagree:
#
#   * kiln/seed.exs, which creates it in the dev database;
#   * `KilnCMS.SchemaExport.SwiftUIReaderFixture` (test/support), which
#     creates it in the test sandbox to generate and drift-check
#     Sources/KilnModels/Kiln.swift.
#
# A field with `:fields` is a `:group`; those are its sub-fields.

%{
  type: %{name: "recipe", label: "Recipe", plural_label: "Recipes"},
  fields: [
    %{name: "serves", label: "Serves", field_type: :integer},
    %{name: "minutes", label: "Minutes", field_type: :integer},
    %{name: "hero", label: "Hero image", field_type: :media},
    %{
      name: "method",
      label: "Method",
      field_type: :text,
      deliver_plain: true,
      plain_breaks: true,
      deliver_portable: true
    },
    %{
      name: "ingredients",
      label: "Ingredients",
      field_type: :group,
      multiple: true,
      fields: [
        %{name: "item", label: "Item", field_type: :string, required: true},
        %{name: "amount", label: "Amount", field_type: :float},
        %{
          name: "unit",
          label: "Unit",
          field_type: :select,
          options: ["g", "ml", "tsp", "tbsp", "pcs"]
        }
      ]
    }
  ]
}
