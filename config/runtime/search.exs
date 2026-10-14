import Config

alias KilnCMS.Config.Env
alias KilnCMS.Search.VectorScan

# A fragment of config/runtime.exs, evaluated by it in EVERY environment — a
# measurement replica is as likely to run `MIX_ENV=dev` as a release.
# Evaluation ORDER matters; see the header of config/runtime.exs before moving
# anything.

# ## Vector scan for measurement runs
#
# Both unset — every deployment that does not ask — leaves `vector_scan:`
# unwritten, and the repo sends exactly the one `SET` it always has. See
# `KilnCMS.Search.VectorScan` for the three modes and what exact mode costs.
#
# The one place in this config where an unusable value **refuses to boot**
# rather than keeping the default and warning, and on purpose: the only reason
# to set either variable is a recall measurement, and a typo that quietly fell
# back to ef_search 40 would produce precisely the approximate numbers the run
# was configured to exclude, labelled as nothing in particular. The `Env`
# readers still warn and collect first, so the shape the value should have had
# is named on stderr above the raise.
ef_search =
  case Env.positive_integer("KILN_HNSW_EF_SEARCH") do
    {:ok, n} -> n
    :unset -> nil
    :unrecognized -> raise "KILN_HNSW_EF_SEARCH must be an integer in 1..1000 (see above)"
  end

exact =
  case Env.fetch("KILN_VECTOR_SEARCH_EXACT") do
    {:ok, exact?} -> exact?
    :unset -> false
    :unrecognized -> raise "KILN_VECTOR_SEARCH_EXACT must be an on/off value (see above)"
  end

# `normalize!/1` owns the range (pgvector's 1..1000) and refuses both at once;
# it raises `ArgumentError`, whose message names the variables.
case VectorScan.normalize!(ef_search: ef_search, exact: exact) do
  :default -> :ok
  mode -> config :kiln_cms, KilnCMS.Repo, vector_scan: VectorScan.to_config(mode)
end
