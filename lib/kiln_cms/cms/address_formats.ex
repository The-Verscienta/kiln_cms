defmodule KilnCMS.CMS.AddressFormats do
  @moduledoc """
  Per-country address conventions for the `:address` field (#2995): which
  parts a country's addresses need, which parts it does not use, and what it
  calls the administrative area, the locality and the postal code ("State",
  "County" and "ZIP code" in the US, "Province" and "Postal code" in Canada).

  The data is `priv/address/formats.json`, generated from the MIT-licensed
  commerceguys/addressing dataset (itself derived from Google's CC BY 4.0
  libaddressinput data). See `priv/address/NOTICE.md` and
  `docs/extending-content.md` ("Address fields"). It is read at compile time; a country the dataset
  does not list (or `nil`) gets the generic format: an address line and a
  city, nothing else required, and no administrative area or postal code
  shown.

  The labels are gettext messages, so they follow the editor's locale.
  """
  use Gettext, backend: KilnCMSWeb.Gettext

  @path Path.join([__DIR__, "..", "..", "..", "priv", "address", "formats.json"])
  @external_resource @path

  @parts ~w(address_line1 locality administrative_area postal_code)

  @formats @path
           |> File.read!()
           |> Jason.decode!()

  @generic %{
    "required" => ["address_line1", "locality"],
    "unused" => ["administrative_area", "postal_code"],
    "administrative_area" => "province",
    "locality" => "city",
    "postal_code" => "postal"
  }

  @typedoc "A format: the parts a country needs and the kinds of its three named parts."
  @type t :: %{
          required: [String.t()],
          unused: [String.t()],
          administrative_area: atom(),
          locality: atom(),
          postal_code: atom()
        }

  @doc "The format for an ISO 3166-1 alpha-2 `country` (the generic one for an unlisted or nil country)."
  @spec get(String.t() | nil) :: t()
  def get(country) do
    @formats
    |> Map.get(country || "", @generic)
    |> then(fn raw ->
      %{
        required: raw["required"],
        unused: raw["unused"],
        administrative_area: kind(raw["administrative_area"]),
        locality: kind(raw["locality"]),
        postal_code: kind(raw["postal_code"])
      }
    end)
  end

  @doc "The parts (`address_line1`, `locality`, ...) `country` requires."
  @spec required(String.t() | nil) :: [String.t()]
  def required(country), do: get(country).required

  @doc "True when `part` is one `country`'s addresses do not use."
  @spec unused?(String.t() | nil, String.t()) :: boolean()
  def unused?(country, part), do: part in get(country).unused

  @doc "The parts a format can require, in editor order."
  @spec parts() :: [String.t()]
  def parts, do: @parts

  # The kinds come from the generated file, so convert only the ones the
  # `label/2` clauses know; an unknown kind (a dataset refresh that adds one)
  # falls through to the generic label instead of creating atoms from data.
  @kinds ~w(area canton county department district do_si emirate island parish prefecture
            province region state town_city post_town suburb city postal zip eircode pin)a
  defp kind(name) do
    Enum.find(@kinds, :unknown, &(Atom.to_string(&1) == name))
  end

  @doc """
  The label of one of the three named parts for `country`:
  `label(:administrative_area, "US")` is "State".
  """
  @spec label(:administrative_area | :locality | :postal_code, String.t() | nil) :: String.t()
  def label(part, country), do: part |> kind_of(country) |> do_label(part)

  defp kind_of(part, country), do: Map.fetch!(get(country), part)

  defp do_label(:area, :administrative_area), do: gettext("Area")
  defp do_label(:canton, :administrative_area), do: gettext("Canton")
  defp do_label(:county, :administrative_area), do: gettext("County")
  defp do_label(:department, :administrative_area), do: gettext("Department")
  defp do_label(:district, :administrative_area), do: gettext("District")
  defp do_label(:do_si, :administrative_area), do: gettext("Province")
  defp do_label(:emirate, :administrative_area), do: gettext("Emirate")
  defp do_label(:island, :administrative_area), do: gettext("Island")
  defp do_label(:parish, :administrative_area), do: gettext("Parish")
  defp do_label(:prefecture, :administrative_area), do: gettext("Prefecture")
  defp do_label(:region, :administrative_area), do: gettext("Region")
  defp do_label(:state, :administrative_area), do: gettext("State")
  defp do_label(_other, :administrative_area), do: gettext("Province")

  defp do_label(:district, :locality), do: gettext("District")
  defp do_label(:post_town, :locality), do: gettext("Post town")
  defp do_label(:suburb, :locality), do: gettext("Suburb")
  defp do_label(:town_city, :locality), do: gettext("Town or city")
  defp do_label(_other, :locality), do: gettext("City")

  defp do_label(:zip, :postal_code), do: gettext("ZIP code")
  defp do_label(:eircode, :postal_code), do: gettext("Eircode")
  defp do_label(:pin, :postal_code), do: gettext("PIN code")
  defp do_label(_other, :postal_code), do: gettext("Postal code")
end
