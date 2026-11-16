defmodule KilnCMS.CMS.AddressFieldTest do
  @moduledoc """
  The built-in `:address` field type (#2279): cast and normalization, postal
  code formats, errors, and the round trip through `ApplyCustomFields`,
  search indexing, filters and sorts.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.{FieldKind, FieldTypes, SearchableFields}
  alias KilnCMS.CMS.FieldTypes.Address
  alias KilnCMS.JsonSchemaValidator

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "adr-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define!(actor, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :page,
          name: "address_#{System.unique_integer([:positive])}",
          label: "An address",
          field_type: :address
        },
        attrs
      ),
      actor: actor
    )
  end

  defp page(actor, fields),
    do:
      CMS.create_page(
        %{title: "Adr", slug: "adr-#{System.unique_integer([:positive])}", custom_fields: fields},
        actor: actor
      )

  defp cast(value), do: Address.cast(value, %{})

  defp postal(country, code) do
    case cast(%{"country" => country, "postal_code" => code}) do
      {:ok, %{"postal_code" => normalized}} -> {:ok, normalized}
      {:error, _} -> :error
    end
  end

  test "is built in, reserved, described and served as generic JSON" do
    assert FieldTypes.get(:address) == Address
    assert Address in FieldTypes.builtin()
    assert :address in FieldTypes.reserved()
    assert Address.name() == :address
    assert is_binary(Address.description())
    assert FieldKind.kind_for(%{field_type: :address}) == :json
  end

  describe "cast" do
    test "stores trimmed parts, drops blanks and upper-cases the country" do
      assert {:ok, address} =
               cast(%{
                 "country" => " gb ",
                 "address_line1" => "  10 Downing Street ",
                 "address_line2" => "   ",
                 "locality" => "London",
                 "administrative_area" => "",
                 "postal_code" => "sw1a 1aa"
               })

      assert address == %{
               "country" => "GB",
               "address_line1" => "10 Downing Street",
               "locality" => "London",
               "postal_code" => "SW1A 1AA"
             }
    end

    test "accepts atom keys" do
      assert {:ok, %{"country" => "FR", "locality" => "Paris"}} =
               cast(%{country: "FR", locality: "Paris"})
    end

    test "a country alone is an address" do
      assert cast(%{"country" => "NZ"}) == {:ok, %{"country" => "NZ"}}
    end

    test "any part without a country is refused" do
      assert {:error, message} = cast(%{"locality" => "Paris"})
      assert message =~ "needs a country"
      assert {:error, _} = cast(%{"country" => "  ", "postal_code" => "75001"})
    end

    test "an empty map is not an address" do
      assert {:error, _} = cast(%{})
      assert {:error, _} = cast(%{"country" => ""})
    end

    test "a country that is not an assigned alpha-2 code is refused" do
      for bad <- ["United Kingdom", "UK", "XK", "G", "GBR", "1A"] do
        assert {:error, message} = cast(%{"country" => bad})
        assert message =~ "ISO 3166-1", bad
      end

      assert {:error, _} = cast(%{"country" => 44})
    end

    test "unknown keys are refused" do
      assert {:error, message} = cast(%{"country" => "GB", "county" => "Kent"})
      assert message =~ "may only have"
      assert {:error, _} = cast(%{"country" => "GB", 7 => "x"})
    end

    test "text parts must be single-line text within their cap" do
      assert {:error, message} = cast(%{"country" => "GB", "address_line1" => "a\nb"})
      assert message =~ "single line"
      assert {:error, _} = cast(%{"country" => "GB", "locality" => "a\tb"})
      assert {:error, _} = cast(%{"country" => "GB", "locality" => "a b"})

      assert {:error, message} =
               cast(%{"country" => "GB", "locality" => String.duplicate("a", 101)})

      assert message =~ "too long"
      assert {:ok, _} = cast(%{"country" => "GB", "locality" => String.duplicate("a", 100)})
      assert {:ok, _} = cast(%{"country" => "GB", "address_line1" => String.duplicate("a", 200)})

      assert {:error, _} =
               cast(%{"country" => "GB", "address_line1" => String.duplicate("a", 201)})

      assert {:error, _} = cast(%{"country" => "GB", "postal_code" => String.duplicate("A", 17)})
      assert {:error, message} = cast(%{"country" => "GB", "locality" => 5})
      assert message =~ "must be text"
    end

    test "anything but a map is refused without raising" do
      for bad <- ["GB", 5, nil, [], [%{}], true, {:a, 1}, ~D[2026-01-01]],
          do: assert({:error, _} = cast(bad), inspect(bad))
    end
  end

  describe "postal codes" do
    test "United Kingdom" do
      assert postal("GB", "SW1A 1AA") == {:ok, "SW1A 1AA"}
      assert postal("GB", "sw1a1aa") == {:ok, "SW1A 1AA"}
      assert postal("GB", "M1 1AE") == {:ok, "M1 1AE"}
      assert postal("GB", "m11ae") == {:ok, "M1 1AE"}
      assert postal("GB", "B33 8TH") == {:ok, "B33 8TH"}
      assert postal("GB", "gir 0aa") == {:ok, "GIR 0AA"}
      assert postal("GB", "SW1A") == :error
      assert postal("GB", "12345") == :error
      assert postal("GB", "SW1A 1A1") == :error
    end

    test "Canada, with and without the space" do
      assert postal("CA", "K1A 0B1") == {:ok, "K1A 0B1"}
      assert postal("CA", "K1A0B1") == {:ok, "K1A 0B1"}
      assert postal("CA", "k1a  0b1") == {:ok, "K1A 0B1"}
      assert postal("CA", "D1A 0B1") == :error
      assert postal("CA", "K1A 0D1") == :error
      assert postal("CA", "90210") == :error
    end

    test "Netherlands" do
      assert postal("NL", "1234 AB") == {:ok, "1234 AB"}
      assert postal("NL", "1234ab") == {:ok, "1234 AB"}
      assert postal("NL", "0234 AB") == :error
      assert postal("NL", "1234") == :error
    end

    test "United States" do
      assert postal("US", "90210") == {:ok, "90210"}
      assert postal("US", "90210-1234") == {:ok, "90210-1234"}
      assert postal("US", "9021") == :error
      assert postal("US", "90210-12") == :error
    end

    test "the other formatted countries" do
      assert postal("DE", "10115") == {:ok, "10115"}
      assert postal("DE", "1011") == :error
      assert postal("FR", "75001") == {:ok, "75001"}
      assert postal("ES", "28013") == {:ok, "28013"}
      assert postal("IT", "00184") == {:ok, "00184"}
      assert postal("AU", "2000") == {:ok, "2000"}
      assert postal("AU", "20000") == :error
      assert postal("CH", "8001") == {:ok, "8001"}
      assert postal("SE", "11122") == {:ok, "111 22"}
      assert postal("SE", "111 22") == {:ok, "111 22"}
      assert postal("JP", "1000001") == {:ok, "100-0001"}
      assert postal("JP", "100-0001") == {:ok, "100-0001"}
      assert postal("JP", "100-001") == :error
      assert postal("BR", "01310100") == {:ok, "01310-100"}
      assert postal("BR", "01310-100") == {:ok, "01310-100"}
      assert postal("IN", "110001") == {:ok, "110001"}
      assert postal("IN", "110 001") == {:ok, "110001"}
      assert postal("IN", "010001") == :error
    end

    test "other countries are free text, upper-cased, within 16 characters" do
      assert postal("IE", "d02 af30") == {:ok, "D02 AF30"}
      assert postal("PL", "00-950") == {:ok, "00-950"}
      assert postal("SG", "238823") == {:ok, "238823"}
      assert postal("AE", "anything  goes") == {:ok, "ANYTHING GOES"}
      assert {:error, _} = cast(%{"country" => "PL", "postal_code" => String.duplicate("1", 17)})
    end

    test "the formats are anchored: trailing and leading text is refused" do
      assert postal("US", "90210 and more") == :error
      assert postal("DE", "x10115") == :error
      assert postal("DE", "10115\n1") == :error
      assert postal("GB", "SW1A 1AA extra") == :error
    end

    test "worst-case input stays fast" do
      {micros, _} =
        :timer.tc(fn ->
          for country <- ~w(US CA GB DE FR NL AU ES IT JP CH SE BR IN),
              code <- [
                String.duplicate("A", 16),
                String.duplicate("1", 16),
                String.duplicate("A1", 8)
              ],
              do: postal(country, code)
        end)

      assert micros < 200_000
    end

    test "the error names the country" do
      assert {:error, message} = cast(%{"country" => "US", "postal_code" => "ABC"})
      assert message =~ "United States"
    end
  end

  describe "json_schema and input_parts" do
    test "the schema accepts what cast stores and refuses unknown keys" do
      schema = Address.json_schema(%{})

      {:ok, stored} =
        cast(%{"country" => "gb", "locality" => "London", "postal_code" => "ec1a1bb"})

      assert JsonSchemaValidator.validate(stored, schema) == :ok
      assert JsonSchemaValidator.validate(nil, schema) == :ok
      assert match?({:error, _}, JsonSchemaValidator.validate(%{"locality" => "x"}, schema))

      assert match?(
               {:error, _},
               JsonSchemaValidator.validate(%{"country" => "GB", "x" => "y"}, schema)
             )
    end

    test "the parts start with a blank-first country select over every country" do
      [country | rest] = Address.input_parts(%{})

      assert %{key: "country", type: "select", options: [{"", _blank} | options]} = country
      assert length(options) == 249
      assert {"GB", "United Kingdom"} in options

      assert Enum.map(rest, & &1.key) ==
               ~w(address_line1 address_line2 locality administrative_area postal_code)

      assert Enum.all?(rest, &(&1.type == "text" and &1.required? == false))
    end
  end

  describe "through ApplyCustomFields" do
    test "an address is stored normalised and is JSON" do
      actor = admin()
      definition = define!(actor)

      assert {:ok, page} =
               page(actor, %{
                 definition.name => %{
                   "country" => "ca",
                   "locality" => " Ottawa ",
                   "administrative_area" => "ON",
                   "postal_code" => "k1a0b1",
                   "address_line1" => "80 Wellington St"
                 }
               })

      assert page.custom_fields[definition.name] == %{
               "country" => "CA",
               "locality" => "Ottawa",
               "administrative_area" => "ON",
               "postal_code" => "K1A 0B1",
               "address_line1" => "80 Wellington St"
             }

      assert {:ok, _} = Jason.encode(page.custom_fields)
    end

    test "a map of blank parts is an empty field, never stored as an empty map" do
      actor = admin()
      definition = define!(actor)

      blanks = Map.new(Address.input_parts(%{}), &{&1.key, ""})
      assert {:ok, page} = page(actor, %{definition.name => blanks})
      refute Map.has_key?(page.custom_fields, definition.name)
    end

    test "a required address needs a country" do
      actor = admin()
      definition = define!(actor, %{required: true})
      blanks = Map.new(Address.input_parts(%{}), &{&1.key, ""})

      assert {:error, error} = page(actor, %{definition.name => blanks})
      assert Exception.message(error) =~ "is required"

      assert {:ok, _} = page(actor, %{definition.name => %{"country" => "DE"}})
    end

    test "an invalid address fails the write, naming the field" do
      actor = admin()
      definition = define!(actor)

      assert {:error, error} = page(actor, %{definition.name => %{"locality" => "Paris"}})
      assert Exception.message(error) =~ "needs a country"

      assert {:error, error} =
               page(actor, %{definition.name => %{"country" => "US", "postal_code" => "ABC"}})

      assert Exception.message(error) =~ "postal code"
    end

    test "a stored address round-trips through the API shape" do
      actor = admin()
      definition = define!(actor)

      {:ok, page} =
        page(actor, %{definition.name => %{"country" => "NL", "postal_code" => "1234ab"}})

      reloaded = CMS.get_page!(page.id, actor: actor)
      stored = reloaded.custom_fields[definition.name]
      assert stored == %{"country" => "NL", "postal_code" => "1234 AB"}

      # Writing the stored value back is idempotent.
      assert Address.cast(stored, %{}) == {:ok, stored}
    end

    test "multiple is cleared, not honoured" do
      actor = admin()
      definition = define!(actor, %{multiple: true})
      refute definition.multiple
    end
  end

  describe "searchable" do
    defp texts(value) do
      definition = %{
        name: "f",
        field_type: :address,
        searchable: true,
        position: 0,
        names_record: false
      }

      SearchableFields.texts(%{"f" => value}, [definition])
    end

    test "indexes the lines, locality, region and postal code, not the country" do
      value = %{
        "country" => "GB",
        "address_line1" => "Zorp House",
        "address_line2" => "Quux Wing",
        "locality" => "Bathtown",
        "administrative_area" => "Somerset",
        "postal_code" => "BA1 1AA"
      }

      assert texts(value) ==
               ["Zorp House", "Quux Wing", "Bathtown", "Somerset", "BA1 1AA"]

      assert texts(%{"country" => "GB"}) == []
      assert texts("not a map") == []
    end

    test "end to end: a street is findable, the country code is not" do
      actor = admin()
      definition = define!(actor, %{searchable: true})

      {:ok, page} =
        page(actor, %{
          definition.name => %{"country" => "CH", "address_line1" => "Streettoken Way"}
        })

      assert page.search_text =~ "Streettoken"
      refute page.search_text =~ " CH"
    end
  end

  describe "filter and sort" do
    test "answers null only, and cannot be sorted" do
      actor = admin()
      definition = define!(actor)
      {:ok, with_value} = page(actor, %{definition.name => %{"country" => "GB"}})

      assert [%{id: id}] =
               CMS.list_pages!(%{custom_filter: %{definition.name => %{"null" => false}}},
                 actor: actor
               )

      assert id == with_value.id

      for filter <- [%{"eq" => "GB"}, %{"contains" => "G"}, %{"in" => "GB,US"}, "GB"] do
        assert {:error, error} =
                 CMS.list_pages(%{custom_filter: %{definition.name => filter}}, actor: actor)

        assert Exception.message(error) =~ "only supports null", inspect(filter)
      end

      assert {:error, error} = CMS.list_pages(%{custom_sort: definition.name}, actor: actor)
      assert Exception.message(error) =~ "not sortable"
    end
  end
end
