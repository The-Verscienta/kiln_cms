defmodule KilnCMS.CMS.FieldTypes.Computed do
  @moduledoc """
  A **computed/derived** custom field (#429): its value comes from the rest of
  the document — reading time, word count, a normalized slug, a price total —
  never from the editor.

  The definition carries a `compute` template
  (`{{ reading_time(body) }} min read`), parsed and validated when the field is
  defined and interpreted by `KilnCMS.CMS.Computed` on every write. Editors see
  it read-only in the inspector, refreshed live as they type.

  ## Where it is evaluated

  Twice, deliberately:

    * **on write** — `KilnCMS.CMS.Changes.ApplyCustomFields` recomputes it into
      `custom_fields` after the editable fields resolve, so the value is stored
      and therefore participates in search, embeddings, `custom_filter` /
      `custom_sort`, and the delivery APIs like any other custom field;
    * **on fire** — `KilnCMS.Firing.CustomFields` recomputes it again when the
      document compiles to artifacts, so **editing a formula reaches published
      content on the next fire**, without a re-save of every record. A stored
      value that has gone stale against a changed formula therefore never
      reaches a fired artifact.

  The write pass **ignores any submitted value**. A computed field is not
  editable through the editor, the JSON:API, GraphQL or MCP: whatever a client
  posts under its key is discarded and replaced by the formula's result.

  ## Contract note

  `cast/2` exists only because `Kiln.FieldType` requires it. Values never
  arrive from a client for this type — the compute pass produces them — so it
  is a defensive pass-through for JSON-native scalars.
  """
  use Kiln.FieldType

  @impl Kiln.FieldType
  def label, do: "Computed"

  @impl Kiln.FieldType
  def cast(value, _definition) when is_binary(value) or is_number(value) or is_boolean(value),
    do: {:ok, value}

  def cast(_value, _definition), do: {:error, "is computed and can't be set directly"}

  # A real input rather than static text: it keeps the field in the editor's
  # normal layout, and `readonly` (not `disabled`) so the value stays
  # selectable and copyable. Whatever it submits is discarded by the compute
  # pass, so it can't be tampered with from the client.
  #
  # No `tabindex: "-1"`: `readonly` already blocks editing while leaving the
  # control focusable, and taking it out of the tab order would put the value
  # out of reach of exactly the keyboard users who need to select it
  # (docs/design-language.md, "Accessible by construction").
  @impl Kiln.FieldType
  def input_attrs(_definition), do: %{readonly: true}

  # A computed value is whatever its expression evaluated to — a single
  # `{{ … }}` template returns the native value, so `{{ word_count(body) }}`
  # delivers an integer while `"{{ … }} min read"` delivers a string. The
  # widget is a text input, so inference would claim `string` for both.
  # Unconstrained is the honest answer: the type is a property of the formula,
  # which the schema has no way to evaluate.
  @impl Kiln.FieldType
  def json_schema(_definition) do
    %{
      "description" =>
        "A computed field. Its JSON type follows the expression: a single " <>
          "`{{ … }}` template delivers the native value (number, boolean, " <>
          "string), an interpolated one always delivers a string."
    }
  end
end
