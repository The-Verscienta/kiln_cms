defmodule KilnCMS.Blocks.UpcasterTest do
  @moduledoc "Phase H — block schema evolution / upcasting (decision D15)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias KilnCMS.Blocks.{Heading, Upcaster}

  defmodule Steps do
    @moduledoc false
    def one_two(map), do: Map.put(map, "two", true)
    def two_three(map), do: Map.put(map, "three", true)
  end

  # Test-only blocks, compiled at runtime so the verifier's warning for the
  # gapped ones is captured here rather than printed while the suite compiles.
  # Each declares version 3; only the steps differ.
  setup_all do
    stderr =
      capture_io(:stderr, fn ->
        compile_block(Contiguous, """
        migrate(from: 1, to: 2, fun: &Steps.one_two/1)
        migrate(from: 2, to: 3, fun: &Steps.two_three/1)
        """)

        compile_block(Gapped, "migrate(from: 1, to: 2, fun: &Steps.one_two/1)")
        compile_block(Leading, "migrate(from: 2, to: 3, fun: &Steps.two_three/1)")
      end)

    %{stderr: stderr}
  end

  defp compile_block(name, migrations) do
    Code.compile_string("""
    defmodule #{inspect(block_module(name))} do
      use Kiln.Block
      alias #{inspect(Steps)}

      block :upcaster_test_#{name |> inspect() |> String.downcase()} do
        version(3)
        field :text, :string
        #{migrations}
      end
    end
    """)
  end

  defp block_module(name), do: Module.concat([__MODULE__, name])

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

  describe "a gap in the migrate chain (#1642)" do
    test "a contiguous chain upcasts through every step" do
      v1 = %{"text" => "x", "_version" => 1}

      assert {:ok, %{"two" => true, "three" => true, "_version" => 3, "text" => "x"}} =
               Upcaster.try_upcast(block_module(Contiguous), v1)
    end

    test "a missing step refuses, and leaves the data and _version as stored" do
      v1 = %{"_type" => "t", "text" => "x", "_version" => 1}

      assert {:error, refusal} = Upcaster.try_upcast(block_module(Gapped), v1)
      assert %{kind: :missing_migration, from: 1, to: 3, missing: 2, type: "t"} = refusal
      assert refusal.detail == "t v1 → v3: no usable `migrate` step from v2"

      # Not even the step that does exist is half-applied.
      log =
        capture_log(fn ->
          assert Upcaster.upcast(block_module(Gapped), v1) == v1
        end)

      assert log =~ "Block upcast refused, block left as stored: t v1 → v3"
    end

    test "a stored version below the first declared step is refused too" do
      v1 = %{"text" => "x", "_version" => 1}
      assert {:error, %{missing: 1}} = Upcaster.try_upcast(block_module(Leading), v1)

      # A version the chain does cover still upcasts.
      assert {:ok, %{"_version" => 3, "three" => true} = v3} =
               Upcaster.try_upcast(block_module(Leading), %{v1 | "_version" => 2})

      refute Map.has_key?(v3, "two")
    end

    test "the read path does not crash on a refusal: the stored map comes back" do
      v2 = %{"text" => "x", "_version" => 2}

      capture_log(fn ->
        assert Upcaster.upcast(block_module(Leading), %{v2 | "_version" => 1}) ==
                 %{v2 | "_version" => 1}

        assert Upcaster.upcast(block_module(Gapped), v2) == v2
      end)
    end

    test "a head-version map is never refused, whatever the chain" do
      v3 = %{"text" => "x", "_version" => 3}
      assert {:ok, ^v3} = Upcaster.try_upcast(block_module(Gapped), v3)
    end

    test "the compile-time check warns about the gapped blocks, not the contiguous one",
         %{stderr: stderr} do
      assert stderr =~ "#{inspect(block_module(Gapped))} (:upcaster_test_gapped, version 3)"
      assert stderr =~ "no `migrate` step leaves version 2"
      assert stderr =~ "#{inspect(block_module(Leading))} (:upcaster_test_leading, version 3)"
      assert stderr =~ "no `migrate` step leaves version 1, so stored v1 blocks"
      assert stderr =~ "becomes a compile error in Kiln 2.0"
      refute stderr =~ "Kiln.Block #{inspect(block_module(Contiguous))}"
    end
  end

  describe "try_upcast_block_map/1" do
    test "resolves the module and upcasts" do
      assert {:ok, %{"level" => 2, "_version" => 2}} =
               Upcaster.try_upcast_block_map(%{
                 "_type" => "heading",
                 "text" => "x",
                 "_version" => 1
               })
    end

    test "passes an unknown or missing _type through" do
      assert {:ok, %{"foo" => "bar"}} = Upcaster.try_upcast_block_map(%{"foo" => "bar"})

      assert {:ok, %{"_type" => "no_such_block_type"}} =
               Upcaster.try_upcast_block_map(%{"_type" => "no_such_block_type"})
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
