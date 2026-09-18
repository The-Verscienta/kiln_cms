# Whether `KILN_ML` compiles the optional ML stack into the build (#1321).
#
# Bumblebee, Nx and EXLA back semantic search, which is **off by default**
# (`config :kiln_cms, KilnCMS.Search, semantic: false`). They cost **671 MB of
# disk** — `deps/exla` alone is 666 MB, 86% of the whole `deps/` tree — plus a
# one-time 110 MB download of the prebuilt XLA archive. Paying that on every
# first `mix setup` for a feature nobody has turned on is what this flag exists
# to stop, so `mix.exs` leaves those three deps out of the tree unless it is on.
#
# The cost is disk and bandwidth, NOT time: measured on an Apple Silicon laptop,
# adding the whole stack to an otherwise-complete build takes ~46 s, of which
# the EXLA NIF is ~16 s. (mix.exs used to claim "~13 min compile, multi-GB RAM".
# That is stale: EXLA links against a *prebuilt* `xla_extension` archive and
# compiles only its own eight C++ files. Thirteen minutes is what building XLA
# itself costs, which `XLA_BUILD=1` asks for and nothing here does.)
#
# This is a standalone `.exs` rather than part of `lib/`, for the same reason
# `strict_test_flag.exs` next to it is: `mix.exs` and `config/dev.exs` /
# `config/test.exs` are all evaluated before `lib/` compiles, so no project
# module is on the code path yet. `mix.exs` needs it to decide the dep list;
# the two env configs need it to decide whether to point Nx at `EXLA.Backend`,
# which they cannot do unconditionally — configuring an application that is not
# in the tree makes Mix warn "You are configuring an application that does not
# really exist" on every boot.
#
# The spelling table is NOT a third copy: it is read from
# `KilnCMS.Config.StrictTestFlag`, which already carries the checked-in-sync
# copy of `KilnCMS.Config.Env`'s. One snippet owning the table means
# `test/kiln_cms/config/strict_test_flag_test.exs`'s sync assertion covers this
# flag too, and `KILN_ML=true` cannot silently mean something different from
# `KILN_STRICT_TEST=true`.
Code.require_file(Path.expand("strict_test_flag.exs", __DIR__))

defmodule KilnCMS.Config.MLFlag do
  @moduledoc false

  @var "KILN_ML"

  @true_values KilnCMS.Config.StrictTestFlag.true_values()
  @false_values KilnCMS.Config.StrictTestFlag.false_values()

  @doc "The environment variable this flag reads."
  def var, do: @var

  @doc """
  Whether `KILN_ML` asks for the optional ML stack: an on-spelling enables it,
  an off-spelling, a blank value or an unset variable does not, and anything
  else stays **off and says so on stderr**.

  That last clause matters more here than it does for `KILN_STRICT_TEST`. A
  misparse means `mix deps.get` quietly leaves Bumblebee/Nx/EXLA out, the build
  compiles clean, and the only symptom is `KilnCMS.Search.ML.available?/0`
  returning false — at which point semantic search reports itself unavailable
  and the operator, who believes they asked for it, has nothing to grep for.
  """
  def enabled?(raw \\ System.get_env(@var)) do
    case raw && raw |> String.trim() |> String.downcase() do
      nil -> false
      # A blank `KILN_ML=` is the routine `.env` artifact: unset, not a mistake.
      "" -> false
      value when value in @true_values -> true
      value when value in @false_values -> false
      _typo -> unrecognized(raw)
    end
  end

  # `raw`, not the normalized form — echoing the operator's own bytes is the
  # only clue they can grep their shell history or CI config for. Same reasoning
  # and wording as `KilnCMS.Config.Env.fetch/1`.
  defp unrecognized(raw) do
    IO.puts(
      :standard_error,
      "#{@var} is set to an unrecognized value (#{inspect(raw)}); " <>
        "building WITHOUT the optional ML stack, so semantic search will report " <>
        "itself unavailable. Use one of: #{Enum.join(@true_values, "/")}, " <>
        "#{Enum.join(@false_values, "/")}."
    )

    false
  end
end
