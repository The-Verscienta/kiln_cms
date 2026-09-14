defmodule KilnCMS.Search.ML do
  @moduledoc """
  Whether the optional ML stack — Bumblebee, Nx, and the EXLA backend behind
  them — was compiled into **this build** (#1321).

  Semantic search has always had a runtime switch (`KilnCMS.Search.semantic?/0`,
  off by default). This is the other, earlier question: the deps themselves are
  opt-in, because they cost 671 MB of `deps/` (666 MB of it `deps/exla`) plus a
  one-time 110 MB archive download — disk a first `mix setup` should not spend
  on a feature that ships disabled. `mix.exs` leaves all three out of the
  dependency tree unless `KILN_ML` is on; see `config/ml_flag.exs`.

  ## Why a module and not `Code.ensure_loaded?/1` at each call site

  Because the answer has to be reached at **compile time**, and at exactly one
  place. A module that names `Bumblebee.load_model/1` or `Nx.Serving` in a
  function body does not merely fail at runtime when the dep is absent — it
  emits an "undefined or private" warning, and `mix compile
  --warnings-as-errors` (CI's `build` job, and `mix precommit`) turns that into
  a failed build. So every module on the semantic path branches on
  `available?/0` in its module body, which compiles one shape or the other and
  leaves no reference to an absent module behind.

  The lean shape is not a stub that pretends to work. `embed/1` and `scores/2`
  return `{:error, %#{inspect(__MODULE__)}.NotCompiledError{}}`, which is the
  `{:error, term()}` their behaviours already document and every caller already
  handles by falling back to keyword search; `KilnCMS.Search.Serving.build/0`
  and `KilnCMS.Search.RerankerServing.build/0` raise, because there is no
  honest value for them to return and nothing calls them unless
  `KilnCMS.Application` decided to start a serving — which it does not do in a
  lean build.

  ## Branch in a module body, never inside a function

  `available?/0` is a compile-time constant, and Elixir 1.19's type checker
  knows it: an `if KilnCMS.Search.ML.available?()` inside a function body is a
  `clause cannot match ... already matched type: dynamic(false)` warning, which
  `--warnings-as-errors` turns into a failed build. That is the checker being
  right — one of the two branches really is dead — so the fix is to move the
  branch out to the module body, where the dead one is never compiled at all.
  Every call site in this project does that, including
  `Mix.Tasks.Kiln.Ml.Note`, `KilnCMS.Application.warn_if_semantic_without_ml/0`
  and `KilnCMS.Search.MLTest`, which defines a different set of tests on each
  leg rather than one set that branches.

  Reporting the value — `IO.puts(KilnCMS.Search.ML.available?())` — is fine
  anywhere; it is *branching* on it at runtime that has no meaning.
  """

  defmodule NotCompiledError do
    @moduledoc """
    Raised (or returned inside an `{:error, _}`) when something asks the
    semantic-search path to do work in a build compiled without the optional ML
    stack. See `KilnCMS.Search.ML`.
    """
    # `defexception` builds the struct but no `t/0`, and `unavailable/0` returns
    # one by name — without this, dialyzer reports an unknown type.
    @type t :: %__MODULE__{message: String.t()}

    defexception message:
                   "semantic search is unavailable: this build was compiled without the " <>
                     "optional ML stack (Bumblebee/Nx/EXLA). Re-run `mix deps.get && mix compile` " <>
                     "with KILN_ML=1 to include it."
  end

  # Evaluated once, here, when this module compiles — deps are compiled and on
  # the code path well before the project's own modules are.
  #
  # `Nx.Serving` rather than `Nx`: it is the module the adapters and the
  # supervision tree actually name, and Nx could in principle arrive as a
  # transitive of something else while Bumblebee is absent. Requiring both is
  # what makes the single answer safe for every call site.
  @available Code.ensure_loaded?(Bumblebee) and Code.ensure_loaded?(Nx.Serving)

  @doc """
  Whether Bumblebee and Nx are present in this build.

  Constant for the life of the build. Call it in a **module body** to pick which
  version of a function to define — see "Branch in a module body" above — or
  anywhere at all to *report* the value. Do not branch on it inside a function.
  """
  @spec available?() :: boolean()
  def available?, do: @available

  @doc """
  The error term the lean adapters return, as an exception struct so it reads
  the same way as the exceptions the real adapters `rescue` and hand back.
  """
  @spec unavailable() :: NotCompiledError.t()
  def unavailable, do: %NotCompiledError{}

  @doc "Raise `NotCompiledError`. For the paths that have no value to return."
  @spec unavailable!() :: no_return()
  def unavailable!, do: raise(NotCompiledError)
end
