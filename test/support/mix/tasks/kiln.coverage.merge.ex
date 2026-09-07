defmodule Mix.Tasks.Kiln.Coverage.Merge do
  @moduledoc """
  Merges the CI shards' raw `:cover` data into one report and enforces the
  coverage floor on the union — without running a test, booting the app, or
  needing a database.

  CI runs the suite under coverage across N shards; each one runs
  `mix coveralls.json --partitions N --export-coverage shard-<n>` and uploads
  `cover/shard-<n>.coverdata`. This task is the other half: it cover-compiles
  the same beams, feeds every `*.coverdata` in `--dir` to `:cover` (a line hit
  by any shard counts as hit), and hands the result to the excoveralls
  reporters — `json` for `cover/excoveralls.json`, which
  `mix kiln.coverage.summary` reads, and `html` for the report and the
  `minimum_coverage` floor in `coveralls.json`, which only that reporter
  checks. A floor failure exits non-zero exactly as `mix coveralls.html` would.

      mix kiln.coverage.merge --dir coverdata --shards 6
      mix kiln.coverage.merge --type json --type lcov

  `--shards N` is a completeness check, and it is the reason this task exists
  rather than `mix coveralls.multiple --import-cover`: excoveralls imports
  whatever files are present and says nothing about how many, so a merge over
  five of six shards (an expired artifact, a partial re-run) would report a
  plausible-looking number against the floor. Here it is an error naming the
  files it found. Passing it is the caller's job; CI passes the shard count.

  Why not `mix coveralls.multiple --import-cover DIR --exclude test`? That
  works — it is what the first cut of the sharding used — but every
  `mix coveralls.*` task goes through `mix test`, and this project's `test`
  alias runs `ash.setup` first. A job that runs zero tests therefore needed a
  Postgres service, a migration run and an app boot, and any failure in those
  turned the coverage gate red after every shard had passed. The import path
  needs none of it: `ExCoveralls.start/2` is compile → import → execute, and
  the reporters read source files and `coveralls.json`.

  Lives under `test/support` rather than `lib/mix/tasks` because excoveralls
  is an `only: :test` dependency: a module under `lib/` that called it would
  compile with "module not available" warnings in every other environment.
  Under `MIX_ENV=test` (its preferred env) it is an ordinary task.
  """
  @shortdoc "Merges the CI shards' :cover data and enforces the coverage floor"

  use Mix.Task

  @default_dir "coverdata"
  @default_types ["json", "html"]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [dir: :string, shards: :integer, type: :keep])

    dir = Keyword.get(opts, :dir, @default_dir)

    types =
      case Keyword.get_values(opts, :type) do
        [] -> @default_types
        types -> types
      end

    files = shard_files!(dir, opts[:shards])

    Mix.Task.run("compile")
    compile_path = Mix.Project.compile_path()

    # The same three calls `ExCoveralls.start/2` makes for `mix coveralls.*`,
    # minus the test run in between. ConfServer holds what the CLI would have
    # parsed; `execute/3` runs every reporter in `type:` in order, so `json`
    # is written before `html` gets to fail the floor.
    ExCoveralls.ConfServer.set(type: types, args: [])
    ExCoveralls.Cover.compile(compile_path)
    ExCoveralls.Cover.import(dir)

    Mix.shell().info(
      "Merged #{length(files)} shard file(s) from #{dir}: #{Enum.map_join(files, ", ", &Path.basename/1)}"
    )

    ExCoveralls.execute(ExCoveralls.ConfServer.get(), compile_path, [])
  end

  @doc """
  The `*.coverdata` files under `dir`, sorted, or a raised error naming what
  is wrong: none at all, or — when `expected` is given — a count that does not
  match it. Public so the guard, which is the point of the task, has a test.
  """
  @spec shard_files!(Path.t(), pos_integer() | nil) :: [Path.t()]
  def shard_files!(dir, expected) do
    files = dir |> Path.join("*.coverdata") |> Path.wildcard() |> Enum.sort()

    cond do
      files == [] ->
        Mix.raise(
          "No *.coverdata files in #{dir}/. Each test shard exports one with " <>
            "`--export-coverage`; download their artifacts into #{dir}/ first."
        )

      is_integer(expected) and length(files) != expected ->
        Mix.raise(
          "Expected #{expected} shard coverdata files in #{dir}/, found #{length(files)}: " <>
            Enum.map_join(files, ", ", &Path.basename/1) <>
            ". A merge over a subset would report a misleading coverage number — " <>
            "re-run the test shards (their artifacts expire) rather than trusting this one."
        )

      true ->
        files
    end
  end
end
