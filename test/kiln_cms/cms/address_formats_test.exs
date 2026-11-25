defmodule KilnCMS.CMS.AddressFormatsTest do
  @moduledoc "Per-country address conventions (#2995)."
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.{AddressFormats, Countries}

  test "the US needs a line, city, state and ZIP code, and calls them that" do
    assert AddressFormats.required("US") ==
             ~w(address_line1 locality administrative_area postal_code)

    assert AddressFormats.label(:administrative_area, "US") == "State"
    assert AddressFormats.label(:postal_code, "US") == "ZIP code"
    assert AddressFormats.label(:locality, "US") == "City"
  end

  test "the UK has a county and a town, and needs no administrative area" do
    assert AddressFormats.label(:administrative_area, "GB") == "County"
    assert AddressFormats.label(:locality, "GB") == "Town or city"
    assert AddressFormats.required("GB") == ~w(address_line1 locality postal_code)
  end

  test "Japan and Ireland use their own words" do
    assert AddressFormats.label(:administrative_area, "JP") == "Prefecture"
    assert AddressFormats.label(:postal_code, "IE") == "Eircode"
    assert AddressFormats.label(:postal_code, "IN") == "PIN code"
  end

  test "a country without a postal system does not use that part" do
    assert AddressFormats.unused?("AE", "postal_code")
    refute AddressFormats.unused?("US", "postal_code")
    refute "postal_code" in AddressFormats.required("AE")
  end

  test "an unknown or missing country gets the generic format" do
    for country <- [nil, "", "ZZ"] do
      assert AddressFormats.required(country) == ~w(address_line1 locality)
      assert AddressFormats.label(:postal_code, country) == "Postal code"
    end
  end

  test "every required part is a part the country uses, and every country is a real one" do
    for country <- ~w(US GB AE AG JP IE IN DE FR BR) do
      format = AddressFormats.get(country)
      assert Countries.valid?(country)
      assert format.required -- (AddressFormats.parts() -- format.unused) == []
    end
  end
end
