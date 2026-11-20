defmodule KilnCMS.CMS.ScalarLists do
  @moduledoc """
  The scalar field types a record-level custom field may hold as a list
  (`multiple: true`, #2289): a list of phrases (`:string`), several terms
  (`:select`), and the typed lists — numbers, dates, times, links, and every
  `Kiln.FieldType` that opts in (`KilnCMS.CMS.FieldTypes.list_capable/0`,
  #2680): the built-in email addresses, phone numbers, colors, slugs and times, and
  any plugin type whose `c:Kiln.FieldType.multiple?/0` answers `true`.

  Each item of a typed list is coerced exactly as the single field of that
  type would be, and stored JSON-native (a number stays a number, a date is
  its ISO-8601 string). A list is record-level only: a link field or group
  sub-field holds one scalar (`KilnCMS.CMS.Changes.ClearMultiple`).

  Types left out on purpose: `:json` (a value may already be an array), the
  composite types (`:range`, `:key_value`, `:link`, `:address`, `:geolocation`,
  `:datetime_range` — a `:group` holds several of those), `:recurrence`
  (already a rule for many dates), `:computed` (derived), `:boolean`
  (a list of them means nothing), `:text` (HTML per item — a `:group`),
  `:user` (its own picker and grants) and any plugin field type that does not
  opt in.
  """

  alias KilnCMS.CMS.FieldTypes

  # The core types, then the opting `Kiln.FieldType`s in registry order.
  @core_types [
    :string,
    :select,
    :integer,
    :float,
    :date,
    :datetime,
    :url
  ]

  @types @core_types ++ FieldTypes.list_capable()

  # Core numbers keep repeats: a quantity may repeat on purpose. A
  # `Kiln.FieldType` drops them only when it says so (`unique_items?/0`).
  @repeatable [:integer, :float]

  @ordered [:integer, :float, :date, :datetime, :time]

  @text [:string, :select, :url, :email, :telephone, :slug]

  @doc "Every scalar type that may be `multiple` on a record-level field."
  @spec types() :: [atom()]
  def types, do: @types

  @doc """
  The typed lists: `types/0` without `:string` and `:select`, whose lists
  (phrases, terms) have rules of their own.
  """
  @spec typed() :: [atom()]
  def typed, do: @types -- [:string, :select]

  @doc """
  Whether a list of `type` drops repeated items: every core type but numbers,
  and a `Kiln.FieldType` whose `c:Kiln.FieldType.unique_items?/0` answers
  `true`.
  """
  @spec distinct?(atom()) :: boolean()
  def distinct?(type) when type in @core_types, do: type not in @repeatable
  def distinct?(type) when type in @types, do: FieldTypes.unique_items?(type)
  def distinct?(_type), do: false

  @doc "Whether items of `type` have an order (numbers, dates, times)."
  @spec ordered?(atom()) :: boolean()
  def ordered?(type), do: type in @ordered

  @doc "Whether items of `type` are text a substring can be matched in."
  @spec text?(atom()) :: boolean()
  def text?(type), do: type in @text
end
