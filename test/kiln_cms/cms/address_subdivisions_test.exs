defmodule KilnCMS.CMS.AddressSubdivisionsTest do
  @moduledoc "Administrative-area lists (#2996)."
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.{AddressSubdivisions, Countries}

  test "the US list holds the states by code" do
    list = AddressSubdivisions.list("US")
    assert {"CA", "California"} in list
    assert {"NY", "New York"} in list
    assert length(list) >= 50
  end

  test "Japan's list is by the dataset's stable ids, with English names" do
    assert {"13", "Tokyo"} in AddressSubdivisions.list("JP")
  end

  test "a country without a list, or no country, has none" do
    assert AddressSubdivisions.list("DE") == nil
    assert AddressSubdivisions.list("ZZ") == nil
    assert AddressSubdivisions.list(nil) == nil
  end

  test "find/2 takes a code or a name, in any case, trimmed" do
    for text <- ["CA", "ca", " California ", "CALIFORNIA"] do
      assert AddressSubdivisions.find("US", text) == {:ok, {"CA", "California"}}
    end

    assert AddressSubdivisions.find("US", "England") == :error
    assert AddressSubdivisions.find("DE", "Bayern") == :error
    assert AddressSubdivisions.find("US", nil) == :error
  end

  test "every list is for a real country, with unique codes and no blanks" do
    for country <- AddressSubdivisions.countries() do
      assert Countries.valid?(country)
      list = AddressSubdivisions.list(country)
      codes = Enum.map(list, &elem(&1, 0))
      assert codes == Enum.uniq(codes)

      assert Enum.all?(list, fn {code, name} ->
               code != "" and name != "" and byte_size(code) <= 100
             end)

      assert length(Enum.uniq_by(codes, &String.downcase/1)) == length(codes)
    end
  end
end
