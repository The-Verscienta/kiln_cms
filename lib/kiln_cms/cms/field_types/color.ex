defmodule KilnCMS.CMS.FieldTypes.Color do
  @moduledoc """
  A **color** custom field (#2278): a hex colour, stored as lowercase
  `#rrggbb`.

  `#rgb` is expanded (`#F80` becomes `#ff8800`). Named colours, `rgb()` and
  alpha channels are not accepted.

  The editor renders a text input with a `pattern`, not `<input type="color">`:
  a colour input cannot represent "no value" (it submits `#000000`), which would
  fill every optional colour field on save.
  """
  use Kiln.FieldType
  use Gettext, backend: KilnCMSWeb.Gettext

  @impl Kiln.FieldType
  def label, do: "Color"

  @impl Kiln.FieldType
  def description do
    gettext("A hex colour such as #ff8800. For a brand accent or a category's badge colour.")
  end

  @impl Kiln.FieldType
  def input_attrs(_definition) do
    %{
      pattern: "#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})",
      placeholder: "#ff8800",
      maxlength: 7,
      autocomplete: "off"
    }
  end

  @impl Kiln.FieldType
  def graphql_kind(_definition), do: :string

  @impl Kiln.FieldType
  def json_schema(_definition),
    do: %{"type" => ["string", "null"], "pattern" => "^#[0-9a-f]{6}$"}

  @impl Kiln.FieldType
  def cast(value, _definition) when is_binary(value) do
    case Regex.run(~r/\A#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})\z/, String.trim(value)) do
      [_, <<r, g, b>>] -> {:ok, String.downcase(<<?#, r, r, g, g, b, b>>)}
      [_, hex] -> {:ok, "#" <> String.downcase(hex)}
      _ -> {:error, message()}
    end
  end

  def cast(_value, _definition), do: {:error, message()}

  defp message, do: "must be a hex colour such as #ff8800"
end
