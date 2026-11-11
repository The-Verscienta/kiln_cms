defmodule KilnDepFixture.FieldTypes.Stars do
  @moduledoc """
  A field type contributed by a plugin compiled as a dependency: 1 to 5.

  Declares `c:Kiln.FieldType.json_schema/1` so the schema-export goldens cover
  a plugin's own schema for its delivered value, not only the widget inference.
  """
  use Kiln.FieldType

  @impl Kiln.FieldType
  def input_type, do: "number"

  @impl Kiln.FieldType
  def input_attrs(_definition), do: %{min: 1, max: 5, step: 1}

  @impl Kiln.FieldType
  def json_schema(_definition),
    do: %{"type" => ["integer", "null"], "minimum" => 1, "maximum" => 5}

  @impl Kiln.FieldType
  def cast(value, _definition) when is_integer(value) and value in 1..5, do: {:ok, value}

  def cast(value, definition) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> cast(int, definition)
      _ -> {:error, "must be a whole number from 1 to 5"}
    end
  end

  def cast(_value, _definition), do: {:error, "must be a whole number from 1 to 5"}
end
