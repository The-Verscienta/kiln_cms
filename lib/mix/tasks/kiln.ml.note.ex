defmodule Mix.Tasks.Kiln.Ml.Note do
  @moduledoc """
  Prints one line saying whether this build carries the optional ML stack.

  The last step of `mix setup` (#1321). Bumblebee, Nx and EXLA back semantic
  search, which ships disabled; they are 671 MB of `deps/` plus a one-time
  110 MB download, and `mix.exs` leaves them out of the dependency tree unless
  `KILN_ML` is on. A first run that silently skipped them would leave a
  developer to discover the missing feature later, and one that silently
  installed them would spend most of a gigabyte unasked — so it says which
  happened, once, where they are already looking.

  It reports `KilnCMS.Search.ML.available?/0`, which is what actually compiled,
  rather than re-reading `KILN_ML`. Those can differ — a typo'd value, or an
  exported variable that arrived after the build did — and in every such case
  the build is the true answer.

      mix kiln.ml.note
  """
  @shortdoc "Says whether the optional ML stack (semantic search) is in this build"

  use Mix.Task

  # `compile` rather than `loadpaths`: within `mix setup` everything is compiled
  # already and this is a no-op, but run on its own it must not fail on a
  # checkout that has not been built.
  @requirements ["compile"]

  # A module-body branch, not an `if` inside `run/1`: `available?/0` is a
  # compile-time constant and Elixir's type checker rejects a runtime branch on
  # one. See `KilnCMS.Search.ML`.
  if KilnCMS.Search.ML.available?() do
    @impl Mix.Task
    def run(_args) do
      Mix.shell().info(
        "Optional ML deps (Bumblebee/Nx/EXLA) are in this build — semantic search is " <>
          "available; turn it on with `config :kiln_cms, KilnCMS.Search, semantic: true`."
      )
    end
  else
    @impl Mix.Task
    def run(_args) do
      Mix.shell().info(
        "Optional heavy deps skipped (Bumblebee/Nx/EXLA, ~671 MB of deps) — " <>
          "set KILN_ML=1 to enable semantic search."
      )
    end
  end
end
