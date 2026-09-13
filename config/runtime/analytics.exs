import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# ## Referrer attribution (#619, phase 2 of docs/advanced-analytics-plan.md)
#
# Off by default. This gate is a plain operator switch (unlike
# `:view_analytics`'s `retention_days`, which is baked into an AshOban `where`
# expression and stays `compile_env`), so it must be — and is — readable at
# runtime: `KilnCMS.Analytics.referrers_enabled?/0` calls
# `Application.get_env/3`, never `compile_env`. See #608 for the defect class
# this avoids.
#
# Only a recognized spelling writes config, so an unset var keeps the
# compiled `false` default. See the header for the accepted spellings.
with {:ok, enabled?} <- Env.fetch("KILN_ANALYTICS_REFERRERS") do
  config :kiln_cms, :analytics_referrers, enabled: enabled?
end

# ## Low-count suppression threshold (#620, phase 3 of docs/advanced-analytics-plan.md)
#
# A referrer category's hit count below this renders — in the dashboard and
# the export — as "< n" rather than an exact number, because a single-digit
# bucket can describe one visitor's arrival (design doc, "Where 'aggregate'
# gets thin: low counts"). Runtime-readable for the same reason as the gate
# above: an operator tightening or loosening this must not need a rebuild.
# `Env.positive_integer/1`, the shared reader (#1009) — an unparseable or
# non-positive value keeps the default and warns rather than being
# interpreted (e.g. silently disabling suppression at threshold 0).
#
# This `config` call deep-merges with the `enabled:` one above (`Config`
# merges successive calls for the same key rather than overwriting), so both
# land in the same `:analytics_referrers` keyword list — see #608 for why
# that merge behavior matters here and can also bite.
with {:ok, threshold} <- Env.positive_integer("KILN_ANALYTICS_LOW_COUNT_THRESHOLD") do
  config :kiln_cms, :analytics_referrers, low_count_threshold: threshold
end
