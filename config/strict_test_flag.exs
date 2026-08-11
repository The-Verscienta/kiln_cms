# Whether `KILN_STRICT_TEST` selects the strict-tenancy CI leg (#419, #646).
#
# This is a standalone `.exs`, not part of `lib/`, and it must stay that way.
# It exists ONLY because `config/test.exs` cannot reach `KilnCMS.Config.Env`:
# `config/config.exs`, `dev.exs`, `test.exs`, `prod.exs` and `e2e.exs` are all
# evaluated before `lib/` compiles, so no project module is on the code path
# yet (`Code.ensure_loaded?/1` on a project module here returns `false` even
# when its `.beam` already exists from a previous build — measured, not
# assumed). See `KilnCMS.Config.Env`'s moduledoc, "`runtime.exs` only" section.
#
# Before this file, `KILN_STRICT_TEST` was read with a bare `== "1"` — the
# ONLY boolean flag in the codebase that did not accept `true`/`yes`/`on` like
# every other one, which is exactly the "#606 shape" bug (#646): a contributor
# who types `KILN_STRICT_TEST=true`, matching every other flag's convention,
# silently got the NON-strict build with nothing skipped and nothing red. The
# raw comparison was also duplicated verbatim in `test/test_helper.exs`, so
# this is the single source both now read, closing that duplication too.
#
# The spelling table is a literal copy of `KilnCMS.Config.Env`'s — it cannot
# `alias`/call that module for the reason above — kept in sync by
# `test/kiln_cms/config/strict_test_flag_test.exs`, which fails if the two
# diverge.
defmodule KilnCMS.Config.StrictTestFlag do
  @moduledoc false

  @true_values ~w(true 1 yes on)
  @false_values ~w(false 0 no off)

  @doc "The same true/false spelling table `KilnCMS.Config.Env` uses, for the sync test."
  def true_values, do: @true_values
  def false_values, do: @false_values

  @doc """
  Whether `KILN_STRICT_TEST` selects strict tenancy: an on-spelling enables it,
  an off-spelling, a blank value or an unset variable does not, and anything
  else stays non-strict **and says so on stderr**.

  That last clause is the whole difference from the first cut of this parser,
  which treated a typo exactly like an unset variable and stayed silent. Its own
  documentation named the cost: `test_helper.exs` then selects `--only
  strict_tenancy` against a fail-open build, which runs zero tests and exits 0,
  indistinguishable from "the leg was never invoked". `KilnCMS.StrictTenancyTest`
  cannot catch it — an excluded test file has nothing to fail — so a silent
  misparse here has no observable symptom at all. That is the #646 shape
  surviving in miniature: the value you typed produced the opposite of what you
  asked for, quietly.

  The objection to warning was that stderr this early is indistinguishable from
  compiler noise. Fair, and it is why the message names the variable, quotes the
  value back, and states the consequence rather than just complaining — but the
  comparison is not "warning versus clean output", it is "warning versus
  nothing". `KilnCMS.Config.Env` writes to stderr for exactly this case, and
  `KilnCMS.Application` does the same for an unparseable cron expression, so a
  reader who greps for either finds the same shape.

  Distinguishing a typo from a deliberate `false` is what makes the message
  possible, and it is why `@false_values` is now load-bearing rather than a list
  that existed only to be compared in a test.
  """
  @spec strict?(String.t() | nil) :: boolean()
  def strict?(raw) do
    case raw && raw |> String.trim() |> String.downcase() do
      nil -> false
      # A blank `KILN_STRICT_TEST=` is the routine `.env` artifact: unset, not a
      # mistake, and not worth a warning.
      "" -> false
      value when value in @true_values -> true
      value when value in @false_values -> false
      _typo -> unrecognized(raw)
    end
  end

  # `raw`, not the normalized form: trimming and downcasing are exactly what
  # caused the mismatch, so echoing the operator's own bytes is the only clue
  # they can grep their shell history or CI config for. Same reasoning, and the
  # same wording, as `KilnCMS.Config.Env.fetch/1`.
  defp unrecognized(raw) do
    IO.puts(
      :standard_error,
      "KILN_STRICT_TEST is set to an unrecognized value (#{inspect(raw)}); " <>
        "compiling WITHOUT strict tenancy, so the strict leg would run no tests. " <>
        "Use one of: #{Enum.join(@true_values, "/")}, #{Enum.join(@false_values, "/")}."
    )

    false
  end
end
