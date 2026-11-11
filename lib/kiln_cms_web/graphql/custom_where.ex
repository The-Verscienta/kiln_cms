defmodule KilnCMSWeb.Graphql.CustomWhere do
  @moduledoc """
  The input types behind `customWhere` (#2290): typed conditions on
  admin-defined custom fields.

  The schema is compiled, so a condition cannot have a field per custom field
  name. It is typed by **kind** instead: `{name: "price", float: {gt: 10}}`.
  Exactly one kind key is allowed per condition; that is checked, with the field's
  definition, by `KilnCMS.CMS.Preparations.CustomFieldQuery`. Operands are real
  GraphQL scalars, so `float: {gt: "abc"}` is refused by validation.

  Conditions are ANDed. At most `KilnCMSWeb.GraphqlLimits.max_custom_conditions/0`
  of them, and `in` takes at most `KilnCMSWeb.GraphqlLimits.max_custom_in_values/0`
  values.
  """
  use Absinthe.Schema.Notation

  @desc """
  A condition on one custom field. Give `name` and exactly one of `string`,
  `int`, `float`, `boolean`, `date` or `dateTime`, which must be the kind of
  the field (`customString`, `customInt`, ...). Conditions in a list are ANDed.
  A list of values (a `multiple` field of numbers, dates, text, ...) takes the
  kind of its items with `eq` (contains), `notEq` (does not contain), `in`
  (contains any) and `isNull`; `customFilter` also takes `has`, `has_all`,
  `has_none` and `count` on it.
  """
  input_object :custom_field_condition do
    field :name, non_null(:string)
    field :string, :string_filter
    field :int, :int_filter
    field :float, :float_filter
    field :boolean, :boolean_filter
    field :date, :date_filter
    field :date_time, :date_time_filter
  end

  @desc "Operators for a text-like custom field. `contains` and `startsWith` ignore case and match text, not patterns."
  input_object :string_filter do
    field :eq, :string
    field :not_eq, :string
    field :in, list_of(non_null(:string))
    field :contains, :string
    field :starts_with, :string
    field :is_null, :boolean
  end

  @desc "Operators for an `integer` custom field."
  input_object :int_filter do
    field :eq, :integer
    field :not_eq, :integer
    field :in, list_of(non_null(:integer))
    field :gt, :integer
    field :gte, :integer
    field :lt, :integer
    field :lte, :integer
    field :is_null, :boolean
  end

  @desc "Operators for a `float` custom field."
  input_object :float_filter do
    field :eq, :float
    field :not_eq, :float
    field :in, list_of(non_null(:float))
    field :gt, :float
    field :gte, :float
    field :lt, :float
    field :lte, :float
    field :is_null, :boolean
  end

  @desc "Operators for a `boolean` custom field."
  input_object :boolean_filter do
    field :eq, :boolean
    field :is_null, :boolean
  end

  @desc "Operators for a `date` custom field."
  input_object :date_filter do
    field :eq, :date
    field :not_eq, :date
    field :in, list_of(non_null(:date))
    field :gt, :date
    field :gte, :date
    field :lt, :date
    field :lte, :date
    field :is_null, :boolean
  end

  @desc "Operators for a `datetime` custom field."
  input_object :date_time_filter do
    field :eq, :datetime
    field :not_eq, :datetime
    field :in, list_of(non_null(:datetime))
    field :gt, :datetime
    field :gte, :datetime
    field :lt, :datetime
    field :lte, :datetime
    field :is_null, :boolean
  end
end
