defmodule KilnCMS.CMS.CountriesTest do
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.Countries

  test "lists all 249 ISO 3166-1 alpha-2 codes, once each, in upper case" do
    codes = Countries.codes()

    assert length(codes) == 249
    assert codes == Enum.uniq(codes)
    assert Enum.all?(codes, &Regex.match?(~r/\A[A-Z]{2}\z/, &1))
  end

  test "every code has a name, and all/0 is sorted by name" do
    all = Countries.all()

    assert length(all) == 249
    assert Enum.all?(all, fn {_code, name} -> is_binary(name) and name != "" end)
    names = Enum.map(all, fn {_code, name} -> String.downcase(name) end)
    assert names == Enum.sort(names)
  end

  test "name/1 and valid?/1 are exact" do
    assert Countries.name("GB") == "United Kingdom"
    assert Countries.name("US") == "United States"
    assert Countries.valid?("JP")

    for bad <- ["gb", "UK", "XK", "EU", "", "GBR", nil, 44, "United Kingdom"] do
      refute Countries.valid?(bad), inspect(bad)
      assert Countries.name(bad) == nil
    end
  end
end
