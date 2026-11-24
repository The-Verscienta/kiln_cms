defmodule KilnCMS.CMS.Types.JsonbSortKey do
  @moduledoc """
  The type of a `custom_sort` key (#3272): one custom field's value read out of
  the record's custom-field map as **jsonb**, a JSON scalar or `nil`.

  `custom_sort` orders by the jsonb value so numbers sort numerically, ISO
  strings lexically, and an off-type value reorders instead of raising
  (`KilnCMS.CMS.Preparations.CustomFieldQuery`). The keyset filter of the next
  page compares that key with the cursor's value, and the comparison has to
  stay in jsonb.

  Left untyped, the key gets its type from the cursor value: from Ash 3.37.5 a
  float cursor value casts both sides to `float`, and a row holding a string
  under the same key fails the read (`cannot cast jsonb string to type double
  precision`). Typed with this, Ash casts the cursor value as a JSON scalar and
  `cast_in_query?/1` keeps any cast out of the SQL, so Postgres binds the value
  as jsonb against the jsonb key, as it did before 3.37.5.
  """
  use Ash.Type

  @impl true
  def storage_type(_constraints), do: :jsonb

  @impl true
  def cast_in_query?(_constraints), do: false

  @impl true
  def cast_input(value, _constraints), do: scalar(value)

  @impl true
  def cast_stored(value, _constraints), do: scalar(value)

  @impl true
  def dump_to_native(value, _constraints), do: scalar(value)

  @impl true
  def dump_to_embedded(value, _constraints), do: scalar(value)

  defp scalar(value)
       when is_nil(value) or is_binary(value) or is_number(value) or is_boolean(value),
       do: {:ok, value}

  defp scalar(_value), do: :error
end
