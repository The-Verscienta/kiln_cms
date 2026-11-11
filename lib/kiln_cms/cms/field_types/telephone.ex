defmodule KilnCMS.CMS.FieldTypes.Telephone do
  @moduledoc """
  A **telephone** custom field (#2278): an international number, stored in
  E.164 form (`"+15551234567"`).

  Spaces, dashes, dots and parentheses are stripped, a leading `00` becomes
  `+`, and what is left must be `+`, a non-zero digit and 6 to 14 more digits.
  This is a *format* check only: Kiln carries no numbering-plan data, so it
  cannot tell a real number from a plausible one. A domestic number
  (`020 7946 0958`) or one with an extension is refused with a hint to include
  the country code, because storing it would make the value mean different
  things to different readers.
  """
  use Kiln.FieldType
  use Gettext, backend: KilnCMSWeb.Gettext

  @max_input 64

  @impl Kiln.FieldType
  def label, do: "Telephone number"

  @impl Kiln.FieldType
  def description do
    gettext(
      "A phone number with its country code, stored as +15551234567. For a switchboard, a clinic or an emergency line."
    )
  end

  @impl Kiln.FieldType
  def input_type, do: "tel"

  @impl Kiln.FieldType
  def input_attrs(_definition), do: %{placeholder: "+44 20 7946 0958"}

  @impl Kiln.FieldType
  def graphql_kind(_definition), do: :string

  @impl Kiln.FieldType
  def json_schema(_definition),
    do: %{"type" => ["string", "null"], "pattern" => "^\\+[1-9][0-9]{6,14}$"}

  @impl Kiln.FieldType
  def cast(value, _definition) when is_binary(value) and byte_size(value) <= @max_input do
    stripped = String.replace(value, ~r/[\s\-\.\(\)]/, "")

    normalized =
      case stripped do
        "00" <> rest -> "+" <> rest
        other -> other
      end

    if Regex.match?(~r/\A\+[1-9][0-9]{6,14}\z/, normalized),
      do: {:ok, normalized},
      else: {:error, message()}
  end

  def cast(_value, _definition), do: {:error, message()}

  defp message,
    do: "must be an international phone number including the country code (e.g. +44 20 7946 0958)"
end
