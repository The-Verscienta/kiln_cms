defmodule KilnCMS.Blocks.UpcasterTest do
  @moduledoc "Phase H — block schema evolution / upcasting (decision D15)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KilnCMS.Blocks.{Heading, Upcaster}

  describe "version metadata" do
    test "the migrate DSL is exposed via Info" do
      assert Kiln.Block.Info.version(Heading) == 2
      assert [%Kiln.Block.Migration{from: 1, to: 2}] = Kiln.Block.Info.migrations(Heading)
    end

    test "a freshly built struct is already at head version" do
      assert %Heading{}._version == 2
    end
  end

  describe "upcast/2" do
    test "runs the migration chain for a stale stored map" do
      v1 = %{"_type" => "heading", "text" => "Hi", "_version" => 1}
      upcast = Upcaster.upcast(Heading, v1)

      assert upcast["level"] == 2
      assert upcast["_version"] == 2
    end

    test "is idempotent on a head-version map" do
      v2 = %{"_type" => "heading", "text" => "Hi", "level" => 4, "_version" => 2}
      assert Upcaster.upcast(Heading, v2) == v2
    end

    test "treats a missing _version as version 1" do
      assert Upcaster.upcast(Heading, %{"text" => "Hi"})["_version"] == 2
    end

    test "preserves data the migration does not touch" do
      v1 = %{"_type" => "heading", "text" => "Keep", "level" => 5, "_version" => 1}
      # level already present → put_new is a no-op; existing value preserved.
      assert Upcaster.upcast(Heading, v1)["level"] == 5
    end
  end

  describe "upcast_block_map/1 (lazy-read resolution by _type)" do
    test "resolves the module and upcasts" do
      assert Upcaster.upcast_block_map(%{"_type" => "heading", "text" => "x", "_version" => 1})[
               "level"
             ] == 2
    end

    test "leaves maps without a known _type unchanged" do
      assert Upcaster.upcast_block_map(%{"foo" => "bar"}) == %{"foo" => "bar"}
    end
  end

  property "upcasting any v1 heading yields a valid, total, head-version map" do
    check all(
            text <- StreamData.string(:printable),
            include_level <- StreamData.boolean(),
            level <- StreamData.integer(1..6)
          ) do
      v1 =
        %{"_type" => "heading", "text" => text, "_version" => 1}
        |> then(fn m -> if include_level, do: Map.put(m, "level", level), else: m end)

      result = Upcaster.upcast(Heading, v1)

      assert result["_version"] == 2
      assert is_integer(result["level"])
      assert result["text"] == text
    end
  end
end
