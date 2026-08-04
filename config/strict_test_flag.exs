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
  Whether `KILN_STRICT_TEST` selects strict tenancy: an on-spelling enables
  it, anything else (unset, blank, an off-spelling, or unrecognized) does not.

  Deliberately does not warn on an unrecognized value, unlike
  `KilnCMS.Config.Env.fetch/1` — `Logger` and `:standard_error` warnings are
  indistinguishable from ordinary compiler noise this early. This narrows the
  original bug (#646) to the four blessed spellings rather than eliminating
  its shape entirely: a value that is neither a recognized on- nor
  off-spelling (a typo, not one of `true`/`1`/`yes`/`on`/`false`/`0`/`no`/`off`)
  still silently selects the NON-strict build, exactly like an unset variable
  — `test_helper.exs`'s `--only strict_tenancy` selection then runs zero
  tests, exit 0, with nothing to distinguish it from "the leg wasn't invoked".
  `KilnCMS.StrictTenancyTest` does NOT catch this: an excluded test file
  cannot fail. CI hardcodes the literal `"1"`, so this residual only matters
  for a contributor invoking the strict leg by hand with a mistyped value.
  """
  @spec strict?(String.t() | nil) :: boolean()
  def strict?(raw) do
    case raw do
      nil -> false
      value -> String.downcase(String.trim(value)) in @true_values
    end
  end
end
