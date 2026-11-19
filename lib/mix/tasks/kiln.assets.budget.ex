defmodule Mix.Tasks.Kiln.Assets.Budget do
  @moduledoc """
  Builds the JavaScript bundles minified and fails when one carries what it
  must not, or (for `public.js`) outgrows its size budget (#2402).

  Signed-out content pages load `public.js` (`assets/js/public.js`, the
  `kiln_public` esbuild profile), not app.js. It is small because it carries
  no LiveView, no Phoenix socket and no console code, and the only thing that
  keeps it that way is a check: one `import` in the wrong file puts all of
  LiveView back on every delivered page, and nothing on the page looks
  different.

  For each bundle it measures the **static load set**: the entry file plus
  every chunk it reaches through `import` statements, which the browser
  fetches before the script runs. Chunks reached only through `import()` are
  left out: the editor's TipTap and Yjs chunks load when an editor opens one,
  not with the page.

    * **public.js** — at most 12,000 B minified and 5,000 B gzipped; none
      of LiveView, Phoenix (the socket), Sortable, topbar, the colocated
      console hooks, the rich-text editor, TipTap or Yjs among its inputs; and
      `js/challenge.js`, the form widget's mount, among them — a public.js
      that lost it would ship every challenge-enabled form unprotected.
    * **app.js** — TipTap, Yjs and the rich-text editor stay behind `import()`.
      Its sizes are printed, not gated: they move with every console feature.

  Builds into `_build/asset_budget/<profile>/`, never `priv/static`, so a
  running dev server's assets and their digests are left alone.

      mix kiln.assets.budget                # both bundles
      mix kiln.assets.budget --only public  # public.js alone, no npm needed

  `--only public` needs nothing but the esbuild binary (`mix esbuild.install
  --if-missing`) and `deps/`; that is what CI runs. app.js also needs
  `assets/node_modules` (`npm install --prefix assets`) and a compiled
  project, for the colocated hooks.
  """
  @shortdoc "Fails when public.js grows past its budget or a bundle imports what it must not"

  use Mix.Task

  @order ["public", "app"]

  @doc false
  # What each bundle is held to. A function, not an attribute: a compiled
  # regex cannot be escaped into code on OTP 28.
  @spec bundle(String.t()) :: map()
  def bundle(name), do: Map.fetch!(bundles(), name)

  defp bundles do
    %{
      "public" => %{
        profile: :kiln_public,
        max_bytes: 12_000,
        max_gzip: 5_000,
        forbidden:
          ~r{phoenix_live_view|/phoenix/|phoenix-colocated|vendor/sortable|vendor/topbar|rich_text|@tiptap|yjs|y-protocols},
        required: ["js/challenge.js"]
      },
      "app" => %{
        profile: :kiln_cms,
        max_bytes: nil,
        max_gzip: nil,
        forbidden: ~r{@tiptap|yjs|y-protocols|rich_text},
        required: []
      }
    }
  end

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [only: :string])

    names =
      case opts[:only] do
        nil -> @order
        name when name in @order -> [name]
        other -> Mix.raise("--only takes public or app, not #{inspect(other)}")
      end

    unless File.exists?(Esbuild.bin_path()) do
      Mix.raise("esbuild is not installed. Run `mix esbuild.install --if-missing` first.")
    end

    # app.js imports the colocated hooks, which `mix compile` writes.
    if "app" in names, do: Mix.Task.run("compile")

    reports = Enum.map(names, &measure(&1, bundle(&1)))

    Mix.shell().info(table(reports))

    case Enum.flat_map(reports, & &1.problems) do
      [] ->
        :ok

      problems ->
        shell = Mix.shell()
        Enum.each(problems, &shell.error/1)

        Mix.raise("""
        #{length(problems)} asset budget problem(s). public.js is the script for \
        signed-out pages and must stay free of LiveView and console code; see \
        assets/js/public.js and docs/frontend-assets.md (#2402).
        """)
    end
  end

  defp measure(name, spec) do
    config = Esbuild.config_for!(spec.profile)
    cd = config[:cd] || File.cwd!()
    outdir = Path.expand("../asset_budget/#{spec.profile}", Mix.Project.build_path())
    metafile = Path.join(outdir, "meta.json")

    File.rm_rf!(outdir)
    File.mkdir_p!(outdir)

    args = budget_args(config[:args], outdir, metafile)

    case System.cmd(Esbuild.bin_path(), args,
           cd: cd,
           env: normalize_env(config[:env] || %{}),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> Mix.raise("esbuild #{spec.profile} exited #{status}:\n#{output}")
    end

    meta = metafile |> File.read!() |> Jason.decode!()
    entry = entry_point(config[:args])
    outputs = closure(meta, entry)

    gzip =
      outputs
      |> Enum.map(&(&1 |> Path.expand(cd) |> File.read!()))
      |> Enum.map(&byte_size(:zlib.gzip(&1)))
      |> Enum.sum()

    report = %{
      name: name,
      file: Path.basename(entry),
      outputs: outputs,
      bytes: Enum.sum(Enum.map(outputs, &meta["outputs"][&1]["bytes"])),
      gzip: gzip,
      inputs: inputs(meta, outputs)
    }

    Map.merge(report, %{spec: spec, problems: check(report, spec)})
  end

  @doc false
  # The profile's own arguments with its output moved under `_build` and the
  # budget's flags added: the same bundle, minified, written where nothing
  # serves it.
  @spec budget_args([String.t()], Path.t(), Path.t()) :: [String.t()]
  def budget_args(args, outdir, metafile) do
    Enum.reject(args, &String.starts_with?(&1, "--outdir=")) ++
      ["--outdir=#{outdir}", "--minify", "--metafile=#{metafile}"]
  end

  @doc false
  # The profile's entry file: its one argument that is not a flag.
  @spec entry_point([String.t()]) :: String.t()
  def entry_point(args), do: Enum.find(args, &(not String.starts_with?(&1, "-")))

  @doc false
  # The output paths the browser loads with `entry`: its own file and every
  # chunk reached through `import` statements, transitively. `import()` chunks
  # are not followed.
  @spec closure(map(), String.t()) :: [String.t()]
  def closure(%{"outputs" => outputs}, entry) do
    root =
      Enum.find_value(outputs, fn {path, out} -> out["entryPoint"] == entry && path end) ||
        raise ArgumentError, "no output in the metafile has entry point #{inspect(entry)}"

    walk([root], outputs, MapSet.new([root]), [root])
  end

  defp walk([], _outputs, _seen, acc), do: Enum.reverse(acc)

  defp walk([path | rest], outputs, seen, acc) do
    next =
      for %{"path" => to, "kind" => "import-statement"} = import <- outputs[path]["imports"] || [],
          not Map.get(import, "external", false),
          not MapSet.member?(seen, to),
          uniq: true,
          do: to

    walk(rest ++ next, outputs, Enum.into(next, seen), Enum.reverse(next) ++ acc)
  end

  @doc false
  # Every source file bundled into `outputs`.
  @spec inputs(map(), [String.t()]) :: [String.t()]
  def inputs(%{"outputs" => all}, outputs) do
    outputs
    |> Enum.flat_map(&Map.keys(all[&1]["inputs"] || %{}))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  # What is wrong with one measured bundle, as lines naming it.
  @spec check(map(), map()) :: [String.t()]
  def check(report, spec) do
    forbidden =
      for input <- report.inputs, Regex.match?(spec.forbidden, input) do
        "#{report.file}: carries #{input}, which it must not (#{inspect(spec.forbidden.source)})"
      end

    missing =
      for input <- spec.required, input not in report.inputs do
        "#{report.file}: no longer carries #{input}, which it must"
      end

    over =
      [
        {spec.max_bytes, report.bytes, "minified"},
        {spec.max_gzip, report.gzip, "gzipped"}
      ]
      |> Enum.filter(fn {max, size, _} -> max && size > max end)
      |> Enum.map(fn {max, size, kind} ->
        "#{report.file}: #{format(size)} B #{kind}, over its #{format(max)} B budget"
      end)

    forbidden ++ missing ++ over
  end

  defp table(reports) do
    rows =
      Enum.map(reports, fn r ->
        budget =
          if r.spec.max_bytes,
            do: "#{format(r.spec.max_bytes)} / #{format(r.spec.max_gzip)}",
            else: "reported only"

        [r.file, to_string(length(r.outputs)), format(r.bytes), format(r.gzip), budget]
      end)

    header = ["bundle", "files", "min (B)", "gzip (B)", "budget (min / gzip)"]

    widths =
      Enum.map(
        Enum.zip_with([header | rows], & &1),
        &Enum.max(Enum.map(&1, fn c -> String.length(c) end))
      )

    Enum.map_join([header | rows], "\n", fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.with_index()
      |> Enum.map_join("  ", fn
        {{cell, width}, 0} -> String.pad_trailing(cell, width)
        {{cell, width}, _} -> String.pad_leading(cell, width)
      end)
      |> String.trim_trailing()
    end)
  end

  @doc false
  @spec format(non_neg_integer()) :: String.t()
  def format(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  # As the esbuild package does for its own runs: a list value is a path list.
  defp normalize_env(env) do
    Map.new(env, fn
      {key, value} when is_list(value) -> {key, Enum.join(value, ":")}
      other -> other
    end)
  end
end
