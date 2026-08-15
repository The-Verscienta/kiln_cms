defmodule Example.FieldTypes.Money do
  @moduledoc """
  A plugin-contributed custom field type (D18): an amount + ISO 4217
  currency code, e.g. `%{"amount" => 49.0, "currency" => "USD"}`. Used as
  `Product`'s `price` custom field (`example_field_definitions.exs`).

  A lighter composite example than the core's
  `KilnCMS.CMS.FieldTypes.Geolocation` (two parts, not four) — see that
  module's moduledoc for the general composite-field-type contract this
  mirrors (`c:Kiln.FieldType.input_parts/1`).

  ## Stored shape

      %{"amount" => 49.0, "currency" => "USD"}

  `amount` is always a float; `currency` is always uppercased. JSON-native
  throughout, so the `custom_fields` jsonb column round-trips it as-is.
  """
  use Kiln.FieldType

  @impl Kiln.FieldType
  def label, do: "Money"

  @impl Kiln.FieldType
  def cast(value, _definition) do
    with {:ok, parts} <- parts(value),
         {:ok, amount} <- amount(Map.get(parts, "amount")),
         {:ok, currency} <- currency(Map.get(parts, "currency")) do
      {:ok, %{"amount" => amount, "currency" => currency}}
    end
  end

  # The two inputs the editor renders, in order.
  @impl Kiln.FieldType
  def input_parts(_definition) do
    [
      %{
        key: "amount",
        label: "Amount",
        type: "number",
        attrs: %{step: "0.01", min: 0, placeholder: "49.00"}
      },
      %{
        key: "currency",
        label: "Currency",
        type: "text",
        attrs: %{maxlength: 3, placeholder: "USD"}
      }
    ]
  end

  # Normalize every accepted input shape to a string-keyed map of raw parts:
  # the editor's part map, a stored map round-tripped by an API client (atom
  # or string keys), or an "amount,currency" string.
  defp parts(value) when is_map(value) and not is_struct(value),
    do: {:ok, Map.new(value, fn {k, v} -> {to_string(k), v} end)}

  defp parts(value) when is_binary(value) do
    case value |> String.split(",") |> Enum.map(&String.trim/1) do
      [amount, currency] -> {:ok, %{"amount" => amount, "currency" => currency}}
      _ -> {:error, format_message()}
    end
  end

  defp parts(_value), do: {:error, format_message()}

  defp amount(value) when is_float(value) and value >= 0, do: {:ok, value}
  defp amount(value) when is_integer(value) and value >= 0, do: {:ok, value / 1}

  defp amount(value) when is_binary(value) do
    case KilnCMS.CMS.Computed.safe_float(String.trim(value)) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> {:error, "amount must be a non-negative number"}
    end
  end

  defp amount(_value), do: {:error, "amount must be a non-negative number"}

  defp currency(value) when is_binary(value) do
    case value |> String.trim() |> String.upcase() do
      code when byte_size(code) == 3 -> {:ok, code}
      _ -> {:error, "currency must be a 3-letter code, e.g. USD"}
    end
  end

  defp currency(_value), do: {:error, "currency must be a 3-letter code, e.g. USD"}

  defp format_message, do: "must be an amount and currency (e.g. 49.00, USD)"
end
