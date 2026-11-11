defmodule Mix.Tasks.Kiln.Export.SchemaTest do
  @moduledoc """
  `mix kiln.export.schema` (#430) — the build-step half of the delivery schema
  export.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Kiln.Export.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "kiln-schema-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "writes JSON to stdout by default, and nothing else" do
    output = capture_io(fn -> Schema.run(["--blocks-only"]) end)

    assert {:ok, document} = Jason.decode(output)
    assert Map.has_key?(document["$defs"], "block")
  end

  test "the summary goes to stderr, so stdout stays pipeable" do
    stderr = capture_io(:stderr, fn -> capture_io(fn -> Schema.run(["--blocks-only"]) end) end)
    assert stderr =~ "block type(s)"
  end

  test "--pretty is still valid JSON, just indented" do
    output = capture_io(fn -> Schema.run(["--blocks-only", "--pretty"]) end)

    assert {:ok, _} = Jason.decode(output)
    assert output =~ "\n  \"$defs\": {"
  end

  # Erlang map order is only sorted up to 32 keys, and `$defs` passes that on any
  # real site — so an unsorted encode would reshuffle the whole file whenever a
  # block or content type is added. A schema written to disk gets committed and
  # diffed, so byte-stability is the point.
  test "JSON keys are sorted, so a committed artifact diffs cleanly" do
    output = capture_io(fn -> Schema.run(["--blocks-only", "--pretty"]) end)

    keys = output |> Jason.decode!() |> Map.get("$defs") |> Map.keys()

    emitted =
      Regex.scan(~r/^    "([^"]+)": \{$/m, output) |> Enum.map(fn [_, key] -> key end)

    assert Enum.sort(keys) == Enum.sort(emitted)
    assert emitted == Enum.sort(emitted)
  end

  test "--out writes a file and creates its directory", %{dir: dir} do
    path = Path.join([dir, "nested", "schema.json"])

    capture_io(fn -> Schema.run(["--blocks-only", "--out", path]) end)

    assert {:ok, document} = path |> File.read!() |> Jason.decode()
    assert Map.has_key?(document["$defs"], "block_heading")
  end

  test "--format ts emits declarations rather than JSON", %{dir: dir} do
    path = Path.join(dir, "kiln.d.ts")

    capture_io(fn -> Schema.run(["--blocks-only", "--format", "ts", "--out", path]) end)

    ts = File.read!(path)
    assert ts =~ "export interface HeadingBlock {"
    assert ts =~ "export type KilnBlock ="
  end

  test "--format kotlin writes kotlinx.serialization models in --package", %{dir: dir} do
    path = Path.join(dir, "Kiln.kt")

    capture_io(fn ->
      Schema.run(
        ["--blocks-only", "--format", "kotlin", "--package", "com.example.kiln"] ++
          ["--out", path]
      )
    end)

    kotlin = File.read!(path)
    assert kotlin =~ "\npackage com.example.kiln\n"
    assert kotlin =~ "public data class HeadingBlock("
    assert kotlin =~ "public sealed interface Block {"
  end

  test "--format kotlin defaults the package to kiln" do
    assert capture_io(fn -> Schema.run(["--blocks-only", "--format", "kotlin"]) end) =~
             "\npackage kiln\n"
  end

  test "--package is checked, and refused for a format that has none" do
    assert_raise Mix.Error, ~r/not a Kotlin package name/, fn ->
      Schema.run(["--blocks-only", "--format", "kotlin", "--package", "com.example-app"])
    end

    assert_raise Mix.Error, ~r/--format kotlin only/, fn ->
      Schema.run(["--blocks-only", "--format", "swift", "--package", "kiln"])
    end
  end

  test "--base-url becomes the document $id" do
    output =
      capture_io(fn ->
        Schema.run(["--blocks-only", "--base-url", "https://cdn.example.com"])
      end)

    assert Jason.decode!(output)["$id"] == "https://cdn.example.com/api/schema"
  end

  test "--all-orgs writes one document per site", %{dir: dir} do
    capture_io(fn -> Schema.run(["--all-orgs", "--blocks-only", "--out", dir]) end)

    written = dir |> File.ls!() |> Enum.sort()
    org_ids = KilnCMS.Accounts.list_org_ids() |> Enum.map(&"#{&1}.json") |> Enum.sort()

    assert written == org_ids
  end

  test "--all-orgs without --out fails loudly rather than writing one file per site" do
    assert_raise Mix.Error, ~r/--out/, fn -> Schema.run(["--all-orgs", "--blocks-only"]) end
  end

  test "an unknown format is rejected" do
    assert_raise Mix.Error, ~r/expected json\|ts\|swift\|kotlin\|openapi/, fn ->
      Schema.run(["--format", "yaml"])
    end
  end

  test "--format openapi writes OpenAPI 3.1 components", %{dir: dir} do
    path = Path.join(dir, "kiln.openapi.json")

    capture_io(fn -> Schema.run(["--blocks-only", "--format", "openapi", "--out", path]) end)

    document = path |> File.read!() |> Jason.decode!()
    assert document["openapi"] == "3.1.0"

    assert document["components"]["schemas"]["block"]["discriminator"]["mapping"]["heading"] ==
             "#/components/schemas/block_heading"

    # Blocks only: there is no document union to be a component.
    refute Map.has_key?(document["components"]["schemas"], "document")
  end

  test "--all-orgs names an OpenAPI file .openapi.json", %{dir: dir} do
    capture_io(fn ->
      Schema.run(["--all-orgs", "--blocks-only", "--format", "openapi", "--out", dir])
    end)

    assert dir |> File.ls!() |> Enum.all?(&String.ends_with?(&1, ".openapi.json"))
  end

  describe "--check" do
    test "passes on a file the same flags wrote, and writes nothing", %{dir: dir} do
      path = Path.join(dir, "kiln.d.ts")
      capture_io(fn -> Schema.run(["--blocks-only", "--format", "ts", "--out", path]) end)
      %File.Stat{mtime: written} = File.stat!(path, time: :posix)

      output =
        capture_io(fn -> Schema.run(["--blocks-only", "--format", "ts", "--check", path]) end)

      assert output =~ "is up to date"
      assert File.stat!(path, time: :posix).mtime == written
    end

    test "fails on a stale file, naming the first differing line", %{dir: dir} do
      path = Path.join(dir, "schema.json")
      capture_io(fn -> Schema.run(["--blocks-only", "--pretty", "--out", path]) end)
      stale = path |> File.read!() |> String.replace(~s("$defs"), ~s("$stale"))
      File.write!(path, stale)

      error =
        assert_raise Mix.Error, fn ->
          Schema.run(["--blocks-only", "--pretty", "--check", path])
        end

      assert error.message =~ "is out of date: line 2 is"
      assert error.message =~ "$stale"
      assert error.message =~ "--out #{path}"
      # Nothing was rewritten.
      assert File.read!(path) == stale
    end

    test "fails on a missing file", %{dir: dir} do
      path = Path.join(dir, "missing.json")

      assert_raise Mix.Error, ~r/missing\.json: no such file/, fn ->
        Schema.run(["--blocks-only", "--check", path])
      end
    end

    test "is refused with --out or --all-orgs", %{dir: dir} do
      assert_raise Mix.Error, ~r/not with --out/, fn ->
        Schema.run(["--blocks-only", "--check", "a.json", "--out", dir])
      end

      assert_raise Mix.Error, ~r/not with --all-orgs/, fn ->
        Schema.run(["--blocks-only", "--check", "a.json", "--all-orgs"])
      end
    end
  end

  # `--all_orgs` looks right and parses as *unknown*; under `OptionParser.parse/2`
  # it would be dropped and the task would quietly export one site instead.
  test "an underscored switch is rejected rather than silently ignored" do
    assert_raise OptionParser.ParseError, ~r/all_orgs/, fn ->
      Schema.run(["--all_orgs", "--blocks-only"])
    end
  end
end
