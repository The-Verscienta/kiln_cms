defmodule KilnCMS.CMS.FieldTypes.Address do
  @moduledoc """
  An **address** custom field (#2279): a postal address stored as one
  normalized object.

      %{
        "country" => "GB",
        "administrative_area" => "England",
        "locality" => "London",
        "postal_code" => "SW1A 1AA",
        "address_line1" => "10 Downing Street",
        "address_line2" => "Westminster"
      }

  Every key but `country` is omitted when blank, and an address with no part
  at all is not a value (the field is empty, never stored as `%{}`).

  ## Rules

    * `country` is an ISO 3166-1 alpha-2 code (`KilnCMS.CMS.Countries`),
      upper-cased; `"gb"` is stored as `"GB"`. A name (`"United Kingdom"`) is
      refused. It is **required as soon as any other part is given**, because
      the rest of an address means nothing without it.
    * Text parts are trimmed, single-line (a newline or other control
      character is refused) and capped: 200 characters for the address lines,
      100 for the locality and administrative area, 16 for the postal code.
    * Any key other than the six above is refused.
    * The postal code is upper-cased and its spacing made canonical. For the
      countries below the **format** is also checked, and a code that cannot
      exist is refused: US, CA, GB, DE, FR, NL, AU, ES, IT, JP, CH, SE, BR and
      IN (`"k1a0b1"` is stored as `"K1A 0B1"`, `"1234ab"` as `"1234 AB"`).
      Every other country is free text, so a code is never refused for a
      country Kiln knows nothing about. This is a *format* check only: it
      cannot tell a real postcode from a well-formed one.

  The postal-code table above is small and hand-written. Each pattern is
  anchored and linear, with no nested quantifiers.

  ## Country-driven labels and required parts (#2995)

  The editor follows the selected country (`KilnCMS.CMS.AddressFormats`, from
  a vetted, MIT-licensed dataset: `docs/extending-content.md` ("Address fields")): the administrative
  area is "State" for the US, "County" for the UK and "Prefecture" for Japan;
  the postal code is a "ZIP code" in the US and an "Eircode" in Ireland; a part
  the country does not use (no postal code in the United Arab Emirates) is not
  offered unless the stored address already has one.

  The parts a country requires (the US needs a line, city, state and ZIP code;
  the UK a line, town and postcode) are marked required **in the editor, on a
  `required` field**: the browser will not submit that form with one empty. The
  server does not enforce it: `cast/2` still accepts a country alone, or any
  subset of parts, so existing API clients, imports and stored values keep
  working. A format is guidance for the person typing, not a validation rule.

  Schema.org `PostalAddress` output and a geocode hand-off to `:geolocation`
  are not implemented.

  Accepted input is the editor's part map, or a map from an API client with
  atom or string keys.

  The value is served through GraphQL as the generic JSON value. It is neither
  filterable (other than for presence) nor sortable. A `searchable` flag
  indexes the lines, locality, administrative area and postal code, not the
  country code.
  """
  use Kiln.FieldType
  use Gettext, backend: KilnCMSWeb.Gettext

  alias KilnCMS.CMS.{AddressFormats, Countries}

  # Display order of the editor; storage is a map, so the order is not stored.
  @keys ~w(country address_line1 address_line2 locality administrative_area postal_code)
  @limits %{
    "address_line1" => 200,
    "address_line2" => 200,
    "locality" => 100,
    "administrative_area" => 100,
    "postal_code" => 16
  }

  @impl Kiln.FieldType
  def label, do: "Address"

  @impl Kiln.FieldType
  def description do
    gettext(
      "A postal address: country, lines, city, region and postal code. For an office, a venue or a clinic. Cannot be filtered or sorted."
    )
  end

  @impl Kiln.FieldType
  def graphql_kind(_definition), do: :json

  @impl Kiln.FieldType
  def json_schema(_definition) do
    text = fn key ->
      %{"type" => "string", "minLength" => 1, "maxLength" => Map.fetch!(@limits, key)}
    end

    %{
      "type" => ["object", "null"],
      "required" => ["country"],
      "properties" => %{
        "country" => %{
          "type" => "string",
          "pattern" => "^[A-Z]{2}$",
          "description" => "ISO 3166-1 alpha-2 country code."
        },
        "administrative_area" => text.("administrative_area"),
        "locality" => text.("locality"),
        "postal_code" => text.("postal_code"),
        "address_line1" => text.("address_line1"),
        "address_line2" => text.("address_line2")
      },
      "additionalProperties" => false
    }
  end

  @impl Kiln.FieldType
  def input_parts(_definition) do
    [
      %{
        key: "country",
        label: gettext("Country"),
        type: "select",
        options: [{"", gettext("Select a country")} | Countries.all()]
      },
      %{
        key: "address_line1",
        label: gettext("Address line 1"),
        type: "text",
        required?: false,
        attrs: %{maxlength: @limits["address_line1"], autocomplete: "address-line1"}
      },
      %{
        key: "address_line2",
        label: gettext("Address line 2"),
        type: "text",
        required?: false,
        attrs: %{maxlength: @limits["address_line2"], autocomplete: "address-line2"}
      },
      %{
        key: "locality",
        label: gettext("City or town"),
        type: "text",
        required?: false,
        attrs: %{maxlength: @limits["locality"], autocomplete: "address-level2"}
      },
      %{
        key: "administrative_area",
        label: gettext("State, province or region"),
        type: "text",
        required?: false,
        attrs: %{maxlength: @limits["administrative_area"], autocomplete: "address-level1"}
      },
      %{
        key: "postal_code",
        label: gettext("Postal code"),
        type: "text",
        required?: false,
        attrs: %{maxlength: @limits["postal_code"], autocomplete: "postal-code"}
      }
    ]
  end

  @doc """
  The editor's parts for the address currently in the form (#2995): labels,
  the required marks and the parts shown follow the selected country.

  The editor calls this in preference to `input_parts/1` when it has the
  value, so the widget changes as the country does. With no country chosen
  yet it is `input_parts/1` (every part, neutral labels).
  """
  def input_parts(definition, value) do
    case country_of(value) do
      nil -> input_parts(definition)
      country -> country_parts(definition, value, country)
    end
  end

  defp country_of(%{} = value) do
    case Map.get(value, "country") || Map.get(value, :country) do
      code when is_binary(code) ->
        code = code |> String.trim() |> String.upcase()
        if Countries.valid?(code), do: code

      _other ->
        nil
    end
  end

  defp country_of(_value), do: nil

  defp country_parts(definition, value, country) do
    format = AddressFormats.get(country)

    # A part the country does not use is hidden, unless it holds something:
    # hiding it would make the next save drop it.
    shown? = fn key ->
      key not in format.unused or filled?(value, key)
    end

    [country_part(definition)]
    |> Kernel.++(
      for part <- input_parts(definition),
          part.key != "country",
          shown?.(part.key) do
        part
        |> Map.put(:required?, part.key in format.required)
        |> relabel(country)
      end
    )
  end

  defp country_part(definition), do: hd(input_parts(definition))

  defp filled?(value, key) do
    case Map.get(value, key) do
      text when is_binary(text) -> String.trim(text) != ""
      _other -> false
    end
  end

  defp relabel(%{key: "administrative_area"} = part, country),
    do: %{part | label: AddressFormats.label(:administrative_area, country)}

  defp relabel(%{key: "locality"} = part, country),
    do: %{part | label: AddressFormats.label(:locality, country)}

  defp relabel(%{key: "postal_code"} = part, country),
    do: %{part | label: AddressFormats.label(:postal_code, country)}

  defp relabel(part, _country), do: part

  @impl Kiln.FieldType
  def cast(value, _definition) when is_map(value) and not is_struct(value) do
    with {:ok, parts} <- parts(value),
         {:ok, texts} <- texts(parts),
         {:ok, country} <- country(Map.get(parts, "country"), texts),
         {:ok, texts} <- postal(texts, country) do
      {:ok, Map.put(texts, "country", country)}
    end
  end

  def cast(_value, _definition), do: {:error, "must be an address with a country"}

  defp parts(map) do
    parts = Map.new(map, fn {key, value} -> {key_name(key), value} end)

    if Map.keys(parts) -- @keys == [],
      do: {:ok, parts},
      else:
        {:error,
         "may only have country, address_line1, address_line2, locality, administrative_area and postal_code"}
  end

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(_key), do: :invalid

  # The trimmed, non-blank text parts (country excluded), or the first error.
  defp texts(parts) do
    Enum.reduce_while(@limits, {:ok, %{}}, fn {key, max}, {:ok, acc} ->
      case text(Map.get(parts, key), key, max) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, text} -> {:cont, {:ok, Map.put(acc, key, text)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp text(nil, _key, _max), do: {:ok, nil}

  defp text(value, key, max) when is_binary(value) do
    text = String.trim(value)

    cond do
      text == "" ->
        {:ok, nil}

      String.length(text) > max ->
        {:error, "#{label_of(key)} is too long (at most #{max})"}

      Regex.match?(~r/[[:cntrl:]\x{2028}\x{2029}]/u, text) ->
        {:error, "#{label_of(key)} must be a single line"}

      true ->
        {:ok, text}
    end
  end

  defp text(_value, key, _max), do: {:error, "#{label_of(key)} must be text"}

  defp label_of(key), do: String.replace(key, "_", " ")

  # No part given at all: the field is empty, which is not an address.
  defp country(nil, texts) when map_size(texts) == 0,
    do: {:error, "needs a country"}

  defp country(value, texts) when is_binary(value) do
    case String.trim(value) do
      "" -> country(nil, texts)
      code -> known_country(String.upcase(code))
    end
  end

  defp country(nil, _texts), do: {:error, "needs a country"}
  defp country(_value, _texts), do: {:error, "country must be an ISO 3166-1 alpha-2 code"}

  defp known_country(code) do
    if Countries.valid?(code),
      do: {:ok, code},
      else: {:error, "country must be an ISO 3166-1 alpha-2 code (like GB or US)"}
  end

  defp postal(%{"postal_code" => code} = texts, country) do
    code = code |> String.upcase() |> String.replace(~r/\s+/u, " ")

    case postal_code(country, code) do
      {:ok, normalized} ->
        {:ok, Map.put(texts, "postal_code", normalized)}

      :error ->
        {:error, "postal code is not a valid #{Countries.name(country)} postal code"}
    end
  end

  defp postal(texts, _country), do: {:ok, texts}

  # Per-country format and canonical spacing. Every pattern is anchored and
  # built from bounded, non-nested quantifiers, so matching is linear in the
  # (16 character) input. Countries without a clause are free text.
  defp postal_code("US", code), do: matching(code, ~r/\A\d{5}(-\d{4})?\z/)
  defp postal_code("DE", code), do: matching(code, ~r/\A\d{5}\z/)
  defp postal_code("FR", code), do: matching(code, ~r/\A\d{5}\z/)
  defp postal_code("ES", code), do: matching(code, ~r/\A\d{5}\z/)
  defp postal_code("IT", code), do: matching(code, ~r/\A\d{5}\z/)
  defp postal_code("AU", code), do: matching(code, ~r/\A\d{4}\z/)
  defp postal_code("CH", code), do: matching(code, ~r/\A\d{4}\z/)

  defp postal_code("CA", code) do
    compact = String.replace(code, " ", "")

    # D, F, I, O, Q and U are never used; W and Z are not a first letter.
    if Regex.match?(
         ~r/\A[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z]\d[ABCEGHJ-NPRSTV-Z]\d\z/,
         compact
       ),
       do: {:ok, String.slice(compact, 0, 3) <> " " <> String.slice(compact, 3, 3)},
       else: :error
  end

  defp postal_code("GB", code) do
    compact = String.replace(code, " ", "")

    cond do
      compact == "GIR0AA" ->
        {:ok, "GIR 0AA"}

      Regex.match?(~r/\A[A-Z]{1,2}\d[A-Z\d]?\d[A-Z]{2}\z/, compact) ->
        {:ok, split_last(compact, 3)}

      true ->
        :error
    end
  end

  defp postal_code("NL", code) do
    compact = String.replace(code, " ", "")

    if Regex.match?(~r/\A[1-9]\d{3}[A-Z]{2}\z/, compact),
      do: {:ok, split_last(compact, 2)},
      else: :error
  end

  defp postal_code("SE", code) do
    compact = String.replace(code, " ", "")

    if Regex.match?(~r/\A\d{5}\z/, compact),
      do: {:ok, String.slice(compact, 0, 3) <> " " <> String.slice(compact, 3, 2)},
      else: :error
  end

  defp postal_code("JP", code) do
    compact = String.replace(code, [" ", "-"], "")

    if Regex.match?(~r/\A\d{7}\z/, compact),
      do: {:ok, String.slice(compact, 0, 3) <> "-" <> String.slice(compact, 3, 4)},
      else: :error
  end

  defp postal_code("BR", code) do
    compact = String.replace(code, [" ", "-"], "")

    if Regex.match?(~r/\A\d{8}\z/, compact),
      do: {:ok, String.slice(compact, 0, 5) <> "-" <> String.slice(compact, 5, 3)},
      else: :error
  end

  defp postal_code("IN", code) do
    compact = String.replace(code, " ", "")
    if Regex.match?(~r/\A[1-9]\d{5}\z/, compact), do: {:ok, compact}, else: :error
  end

  defp postal_code(_country, code), do: {:ok, code}

  defp matching(code, regex), do: if(Regex.match?(regex, code), do: {:ok, code}, else: :error)

  defp split_last(text, count) do
    size = String.length(text) - count
    String.slice(text, 0, size) <> " " <> String.slice(text, size, count)
  end
end
