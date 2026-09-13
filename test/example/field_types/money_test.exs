defmodule Example.FieldTypes.MoneyTest do
  @moduledoc """
  The in-tree example overlay's composite field type, as a pure unit test —
  no database, no activation. The example catalog stays dormant in a core
  build (`Kiln.CoreAgnosticTest`), but `projects/` is in `elixirc_paths` for
  every env, so the module compiles here and its `cast/2` can be exercised
  directly.

  The point is less the type than the overlay: it is the worked reference a
  downstream team copies, so its `cast/2` semantics are pinned here rather
  than left to be re-derived from a reading of the source.
  """
  use ExUnit.Case, async: true

  alias Example.FieldTypes.Money

  @definition %{name: "price"}

  describe "cast/2 accepts" do
    test "the editor's string-keyed part map" do
      assert Money.cast(%{"amount" => "49.00", "currency" => "usd"}, @definition) ==
               {:ok, %{"amount" => 49.0, "currency" => "USD"}}
    end

    test "an atom-keyed map, as an API client round-tripping a stored value" do
      assert Money.cast(%{amount: 49.0, currency: "USD"}, @definition) ==
               {:ok, %{"amount" => 49.0, "currency" => "USD"}}
    end

    test "an integer amount, widened to a float" do
      assert {:ok, %{"amount" => amount}} =
               Money.cast(%{"amount" => 49, "currency" => "USD"}, @definition)

      assert amount === 49.0
    end

    test "the comma-separated string form" do
      assert Money.cast("49.00, usd", @definition) ==
               {:ok, %{"amount" => 49.0, "currency" => "USD"}}
    end

    test "zero" do
      assert Money.cast(%{"amount" => "0", "currency" => "EUR"}, @definition) ==
               {:ok, %{"amount" => 0.0, "currency" => "EUR"}}
    end
  end

  describe "cast/2 rejects" do
    test "a negative amount" do
      assert {:error, message} = Money.cast(%{"amount" => "-1", "currency" => "USD"}, @definition)
      assert message == "amount must be a non-negative number"
    end

    test "an amount with trailing junk" do
      assert {:error, "amount must be a non-negative number"} =
               Money.cast(%{"amount" => "49usd", "currency" => "USD"}, @definition)
    end

    test "a currency that is not three letters" do
      assert {:error, message} = Money.cast(%{"amount" => "49", "currency" => "US"}, @definition)
      assert message == "currency must be a 3-letter code, e.g. USD"
    end

    test "a string that is not amount-and-currency" do
      assert {:error, message} = Money.cast("49.00", @definition)
      assert message == "must be an amount and currency (e.g. 49.00, USD)"
    end

    test "a value that is neither a map nor a string" do
      assert {:error, "must be an amount and currency (e.g. 49.00, USD)"} =
               Money.cast(49.0, @definition)
    end
  end

  # The reason `cast/2` parses through `Kiln.FieldType.parse_float/1` rather
  # than `Float.parse/1`: the latter *raises* on a literal that overflows a
  # double under this project's pinned Elixir, and `cast/2` runs on every
  # content write, including public ones. A raise there is a 500, not the
  # validation message this asserts.
  test "an amount that overflows a double fails validation rather than raising" do
    huge = String.duplicate("9", 400) <> ".0"

    assert Money.cast(%{"amount" => huge, "currency" => "USD"}, @definition) ==
             {:error, "amount must be a non-negative number"}
  end
end
