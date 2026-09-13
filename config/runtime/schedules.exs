import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it at the position this
# block always occupied. Evaluation ORDER matters here — see the header of
# config/runtime.exs before moving anything.

# ## Outbound link checking (#474)
#
# When the sweep runs, and who it says it is. Both are safe to leave alone:
# checking is opt-in per site, so an unconfigured deployment makes no outbound
# requests at all. The user-agent is worth setting on a public site — it is what
# an operator on the receiving end reads before deciding whether to block you,
# and a contact URL of your own beats Kiln's.
if cron = System.get_env("KILN_LINK_CHECK_CRON") do
  config :kiln_cms, :link_check_cron, cron
end

# ## Editorial tasks (#501)
#
# When the due-soon/overdue digest email runs. Safe to leave scheduled
# everywhere: with no tasks assigned in any org, the sweep enqueues nothing.
if cron = System.get_env("KILN_TASK_DIGEST_CRON") do
  config :kiln_cms, :task_digest_cron, cron
end

# ## Events: the "what's on" index (#766)
#
# When the occurrence sweep runs. The interval is how stale the listing may be —
# an event that has finished keeps its place until the next run — so shorten it
# on a site whose events turn over during the day, and set `false` (or drive
# `KilnCMS.Events.Sweep.run/0` from your own scheduler) to turn it off.
if cron = System.get_env("KILN_OCCURRENCE_SWEEP_CRON") do
  config :kiln_cms, :occurrence_sweep_cron, cron
end

# When the federation replay nonce store is swept (#967). `false` disables;
# the store is only written when federation is on.
if cron = System.get_env("KILN_FEDERATION_NONCE_SWEEP_CRON") do
  config :kiln_cms, :federation_nonce_sweep_cron, cron
end

# ## Content lifecycles: the freshness sweep (docs/content-lifecycles.md)
#
# When the sweep looks for content that has gone past its review cadence and
# dispatches the `health_overdue` / `health_expired` automation triggers. Safe
# to leave scheduled everywhere: with no review cadences set, it matches nothing
# and dispatches nothing. Daily is the right period — freshness is a cadence
# measured in months, so a reminder that lands at 07:30 rather than 07:31 is the
# same reminder. `false` (or driving `KilnCMS.CMS.HealthSweep.run/0` yourself)
# turns it off.
if cron = System.get_env("KILN_HEALTH_SWEEP_CRON") do
  config :kiln_cms, :health_sweep_cron, cron
end

# And whether booting queues the one-off backfill that gives pre-existing
# content its first value. On by default because the alternative is an upgrade
# step someone has to remember, and the index is simply empty until they do.
# Deduplicated for a day, and a redundant run writes nothing — so the honest
# reason to turn this off is wanting to run `mix kiln.occurrences.backfill`
# yourself, at a time you choose.
#
# `Env.fetch/1` rather than `Env.flag/2`, and that is load-bearing: this file is
# evaluated in EVERY environment and AFTER `config/test.exs`, so a `flag(…,
# true)` default would overwrite the `false` the test config sets — turning the
# suite's application boot back into a committed `oban_jobs` row. Only a
# recognized spelling writes anything here; unset leaves whichever default is
# already configured.
with {:ok, enabled?} <- Env.fetch("KILN_OCCURRENCE_BACKFILL_ON_BOOT") do
  config :kiln_cms, :occurrence_backfill_on_boot, enabled?
end

if user_agent = System.get_env("KILN_LINK_CHECK_USER_AGENT") do
  config :kiln_cms, KilnCMS.Links.External, user_agent: user_agent
end
