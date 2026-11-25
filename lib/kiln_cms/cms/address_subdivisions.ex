defmodule KilnCMS.CMS.AddressSubdivisions do
  @moduledoc """
  The first-level administrative areas (states, provinces, prefectures,
  counties) of the countries that have a known list (#2996): 62 countries,
  such as the US states, the Canadian provinces and territories, the
  Japanese prefectures and the UK's local authorities.

  The data is `priv/address/subdivisions.json`, generated from the MIT-licensed
  commerceguys/addressing dataset (derived from Google's CC BY 4.0
  libaddressinput data); see `priv/address/NOTICE.md` and
  `docs/extending-content.md` ("Address fields"). An area is a stable
  `{code, name}`: `{"CA", "California"}` for the US, `{"13", "Tokyo"}` for
  Japan. The code is what an address stores; the name is display text (Latin
  script, English where the dataset has one).

  A country not in the list has no known areas, and its administrative area
  stays free text.
  """

  @path Path.join([__DIR__, "..", "..", "..", "priv", "address", "subdivisions.json"])
  @external_resource @path

  @areas @path |> File.read!() |> Jason.decode!()

  # Per country: the `{code, name}` pairs in dataset order, and lookups by
  # lowercased code and name, built once at compile time.
  @index Map.new(@areas, fn {country, pairs} ->
           list = Enum.map(pairs, fn [code, name] -> {code, name} end)

           by_code = Map.new(list, fn {code, _} = pair -> {String.downcase(code), pair} end)
           by_name = Map.new(list, fn {_, name} = pair -> {String.downcase(name), pair} end)

           {country, %{list: list, by_code: by_code, by_name: by_name}}
         end)

  @doc "The `{code, name}` areas of `country`, or `nil` when it has no known list."
  @spec list(String.t() | nil) :: [{String.t(), String.t()}] | nil
  def list(country) do
    case Map.fetch(@index, country || "") do
      {:ok, %{list: list}} -> list
      :error -> nil
    end
  end

  @doc "The countries that have a list."
  @spec countries() :: [String.t()]
  def countries, do: Map.keys(@index)

  @doc """
  The area `text` names in `country`: a code (`"ca"`) or a name
  (`"California"`), ignoring case and surrounding space. Returns
  `{:ok, {code, name}}`, or `:error` when the country has no list or `text`
  is in neither column.
  """
  @spec find(String.t() | nil, String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def find(country, text) when is_binary(text) do
    with {:ok, %{by_code: by_code, by_name: by_name}} <- Map.fetch(@index, country || "") do
      key = text |> String.trim() |> String.downcase()

      case by_code do
        %{^key => pair} -> {:ok, pair}
        _ -> Map.fetch(by_name, key)
      end
    end
  end

  def find(_country, _text), do: :error
end
