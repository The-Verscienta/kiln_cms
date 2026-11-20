defmodule Mix.Tasks.Kiln.Assets.BudgetTest do
  @moduledoc """
  The asset budget gate (#2402), against hand-written esbuild metafiles so it
  runs without esbuild or `node_modules`. A gate that only ever passes proves
  nothing, so each refusal is asserted: a forbidden input, a lost required
  one, a bundle over budget — and the static closure that decides what counts,
  since following `import()` would charge public.js for chunks it never loads.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Kiln.Assets.Budget

  # app.js-shaped: the entry statically imports a shared chunk, which imports
  # another; the editor chunk is reached only through `import()`, and itself
  # imports the shared chunk.
  @meta %{
    "outputs" => %{
      "../_build/asset_budget/kiln_cms/app.js" => %{
        "entryPoint" => "js/app.js",
        "bytes" => 1_000,
        "imports" => [
          %{"path" => "../_build/asset_budget/kiln_cms/chunk-A.js", "kind" => "import-statement"},
          %{
            "path" => "../_build/asset_budget/kiln_cms/rich_text-X.js",
            "kind" => "dynamic-import"
          },
          %{"path" => "https://cdn.test/x.js", "kind" => "import-statement", "external" => true}
        ],
        "inputs" => %{"js/app.js" => %{"bytesInOutput" => 900}}
      },
      "../_build/asset_budget/kiln_cms/chunk-A.js" => %{
        "bytes" => 200,
        "imports" => [
          %{"path" => "../_build/asset_budget/kiln_cms/chunk-B.js", "kind" => "import-statement"}
        ],
        "inputs" => %{"../deps/phoenix/priv/static/phoenix.mjs" => %{"bytesInOutput" => 200}}
      },
      "../_build/asset_budget/kiln_cms/chunk-B.js" => %{
        "bytes" => 30,
        "imports" => [],
        "inputs" => %{"js/shared.js" => %{"bytesInOutput" => 30}}
      },
      "../_build/asset_budget/kiln_cms/rich_text-X.js" => %{
        "bytes" => 50_000,
        "imports" => [
          %{"path" => "../_build/asset_budget/kiln_cms/chunk-A.js", "kind" => "import-statement"}
        ],
        "inputs" => %{
          "js/rich_text.js" => %{"bytesInOutput" => 1_000},
          "node_modules/@tiptap/core/dist/index.js" => %{"bytesInOutput" => 49_000}
        }
      }
    }
  }

  defp report(attrs) do
    Map.merge(
      %{
        file: "public.js",
        inputs: ["js/challenge.js", "js/public.js"],
        bytes: 6_000,
        gzip: 2_300
      },
      attrs
    )
  end

  describe "closure/2" do
    test "follows import statements transitively and leaves import() chunks out" do
      assert Budget.closure(@meta, "js/app.js") == [
               "../_build/asset_budget/kiln_cms/app.js",
               "../_build/asset_budget/kiln_cms/chunk-A.js",
               "../_build/asset_budget/kiln_cms/chunk-B.js"
             ]
    end

    test "the inputs of the static set exclude what only the dynamic chunk carries" do
      inputs = Budget.inputs(@meta, Budget.closure(@meta, "js/app.js"))

      assert inputs == ["../deps/phoenix/priv/static/phoenix.mjs", "js/app.js", "js/shared.js"]
      assert Budget.check(report(%{file: "app.js", inputs: inputs}), Budget.bundle("app")) == []
    end

    test "an entry the metafile does not have is an error, not an empty set" do
      assert_raise ArgumentError, ~r/js\/public.js/, fn ->
        Budget.closure(@meta, "js/public.js")
      end
    end
  end

  describe "check/2 for public.js" do
    test "a small bundle carrying the challenge mount passes" do
      assert Budget.check(report(%{}), Budget.bundle("public")) == []
    end

    test "LiveView, the Phoenix socket or the editor among its inputs is refused" do
      for input <- [
            "../deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js",
            "../deps/phoenix/priv/static/phoenix.mjs",
            "../_build/dev/phoenix-colocated/kiln_cms/index.js",
            "vendor/sortable.js",
            "js/rich_text.js",
            "node_modules/@tiptap/core/dist/index.js",
            "node_modules/yjs/dist/yjs.mjs"
          ] do
        assert [problem] =
                 Budget.check(
                   report(%{inputs: [input, "js/challenge.js"]}),
                   Budget.bundle("public")
                 ),
               input

        assert problem =~ "public.js: carries #{input}"
      end
    end

    test "phoenix_html is allowed: it is not the socket" do
      inputs = ["../deps/phoenix_html/priv/static/phoenix_html.js", "js/challenge.js"]
      assert Budget.check(report(%{inputs: inputs}), Budget.bundle("public")) == []
    end

    test "losing js/challenge.js is refused" do
      assert [problem] =
               Budget.check(report(%{inputs: ["js/public.js"]}), Budget.bundle("public"))

      assert problem =~ "no longer carries js/challenge.js"
    end

    test "over budget, minified or gzipped, is refused with both numbers" do
      assert [min, gzip] =
               Budget.check(report(%{bytes: 12_001, gzip: 5_001}), Budget.bundle("public"))

      assert min == "public.js: 12,001 B minified, over its 12,000 B budget"
      assert gzip == "public.js: 5,001 B gzipped, over its 5,000 B budget"
    end
  end

  describe "check/2 for app.js" do
    test "sizes are reported, not gated" do
      app = report(%{file: "app.js", inputs: ["js/app.js"], bytes: 10_000_000, gzip: 9_000_000})
      assert Budget.check(app, Budget.bundle("app")) == []
    end

    test "the editor in the static set is refused" do
      app = report(%{file: "app.js", inputs: ["js/app.js", "node_modules/yjs/dist/yjs.mjs"]})
      assert [problem] = Budget.check(app, Budget.bundle("app"))
      assert problem =~ "app.js: carries node_modules/yjs/dist/yjs.mjs"
    end
  end

  describe "budget_args/3 and entry_point/1" do
    test "moves the output under _build and adds the budget's flags" do
      args = ~w(js/public.js --bundle --format=esm --outdir=../priv/static/assets/js)

      assert Budget.budget_args(args, "/b/out", "/b/out/meta.json") ==
               ~w(js/public.js --bundle --format=esm --outdir=/b/out --minify --metafile=/b/out/meta.json)

      assert Budget.entry_point(args) == "js/public.js"
    end

    test "the real profiles never write to priv/static" do
      for profile <- [:kiln_public, :kiln_cms] do
        args = Application.fetch_env!(:esbuild, profile)[:args]
        built = Budget.budget_args(args, "/b/out", "/b/out/meta.json")

        refute Enum.any?(built, &String.contains?(&1, "priv/static")), inspect(profile)
      end
    end
  end

  test "format/1 groups thousands" do
    assert Budget.format(0) == "0"
    assert Budget.format(999) == "999"
    assert Budget.format(257_647) == "257,647"
    assert Budget.format(1_234_567) == "1,234,567"
  end
end
