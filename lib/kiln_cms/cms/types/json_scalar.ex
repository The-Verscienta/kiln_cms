defmodule KilnCMS.CMS.Types.JsonScalar do
  @moduledoc """
  One JSON scalar (a string, number or boolean, or `nil`) held as `jsonb`.

  The type of a custom-field sort key (`KilnCMS.CMS.Preparations.CustomFieldQuery`):
  one key of the custom-field map, a `jsonb` value whose JSON type varies by row, since
  a field retyped after rows were written keeps their old values. Typed this
  way, a keyset cursor value is bound back as `$1::jsonb` and compared the way
  the sort orders, by jsonb rules: numbers numerically, strings by text, and a
  number against a string by JSON type.

  Untyped, ash (from 3.37.5) types the cursor literal itself and casts the sort
  expression to match, so a page after a `3.5` cast the key to `::float`
  and failed on any row holding a string.

  A list or a map is refused: the sort key never holds one (it reads those as
  `NULL`), so a cursor carrying one was not issued by Kiln.
  """
  use Ash.Type

  defguardp scalar?(value)
            when is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value)

  @impl Ash.Type
  def storage_type(_constraints), do: :jsonb

  @impl Ash.Type
  def cast_input(value, _constraints) when scalar?(value), do: {:ok, value}
  def cast_input(_value, _constraints), do: :error

  @impl Ash.Type
  def cast_stored(value, _constraints) when scalar?(value), do: {:ok, value}
  def cast_stored(_value, _constraints), do: :error

  @impl Ash.Type
  def dump_to_native(value, _constraints) when scalar?(value), do: {:ok, value}
  def dump_to_native(_value, _constraints), do: :error

  @impl Ash.Type
  def matches_type?(value, _constraints), do: scalar?(value)
end
