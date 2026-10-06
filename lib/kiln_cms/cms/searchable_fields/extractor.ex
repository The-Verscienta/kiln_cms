defmodule KilnCMS.CMS.SearchableFields.Extractor do
  @moduledoc """
  A project's own reading of its searchable custom fields (#1585 follow-up).

  `KilnCMS.CMS.SearchableFields` turns a flagged field's value into text by a
  rule that knows nothing about the field: strings (HTML stripped), numbers,
  and the strings and numbers nested in lists and maps. That is right for a
  value stored as a real list or map. It is wrong for a site whose
  structured values are stored as **JSON text** in a `:text` field — common
  in content migrated from another CMS — because a JSON document is a
  string, so its braces and key names are indexed as words. It is also
  blind to which keys of a structured value are worth searching: a
  `{"language", "name"}` pair's `language` is noise in every record.

  An extractor answers both, per field. Configure one with

      config :kiln_cms, KilnCMS.CMS.SearchableFields, extractor: MyApp.SearchText

  and it is asked about every flagged field, in order:

    * `c:texts/2` returns the texts a value contributes, or `:default` to
      leave that field to the generic rule (`KilnCMS.CMS.SearchableFields.default_texts/1`,
      which an extractor may also call on a value it decoded itself).
    * `c:order/1` (optional) orders the flagged definitions. The text is
      appended in this order, and an embedding model reads only so many
      tokens of it, so the order decides what a long record's vector is
      about. Without it, the order is the editor's (`position`, then name).

  Both run on every content write that indexes and on every fire, inside
  the write: keep them pure and cheap. A raise is caught and logged, and
  the field falls back to the generic rule, so an extractor bug never fails
  an editor's save.
  """

  @typedoc "A `KilnCMS.CMS.FieldDefinition` (or any map with its `name`/`position`)."
  @type definition :: map()

  @callback texts(definition(), value :: term()) :: [String.t()] | :default
  @callback order([definition()]) :: [definition()]

  @optional_callbacks order: 1
end
