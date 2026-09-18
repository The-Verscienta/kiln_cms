import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.
#
# ## Boolean environment variables
#
# Every on/off variable — in this file and in every fragment under
# `config/runtime/` that it evaluates — goes through `KilnCMS.Config.Env`: one
# parser, one set of accepted spellings, one rule for a value it cannot read
# (#607). Do not hand-roll an eighth: matching the raw value is how
# `DATABASE_SSL=True` came to silently disable Postgres TLS (#606) and
# `VISUAL_EDITING_ENABLED=False` came to leave the bridge on.
#
#   * trimmed and downcased, so `TRUE`, `On` and `" true "` all work
#   * `true`/`1`/`yes`/`on` and `false`/`0`/`no`/`off` are recognized
#   * anything else is never interpreted: it keeps the default and warns, so a
#     typo can flip nothing in either direction
#
# `Env.flag/2` returns a boolean; `Env.fetch/1` distinguishes "unset" from
# "explicitly false" for the flags that must only override config when the
# operator actually set them. See the moduledoc for the per-flag caveats — this
# fails to the *default*, which is only the safe side when the default is.
#
# ## Integer environment variables
#
# `Env.positive_integer/1`, on the same terms and for the same reason (#1009).
# Four variables here had each hand-rolled the parse, the positivity check and
# the warning, so "unparseable means the default, not a crash" was four
# opportunities to disagree — and `IO.warn` alone never reached the Sentry
# replay that #634 added, so a typo warned on container stdout and nowhere else.
#
# ## Everything else
#
# Same rule, and it is the rule rather than the parser that matters: a rejected
# value owes the operator a *collected* warning, never a bare `IO.warn` (#912).
# `Env.one_of/2` covers an enum — `KILN_PROVENANCE_AI_DISCLOSURE` is the only
# one — and `Env.record_unusable/3` is the escape hatch for a shape with no
# reader, which today means `KILN_PROVENANCE_RETIRED_KEY_FILES` alone. There
# should be no `IO.warn` left in this file or in any fragment; a new one is a
# warning that reaches container stdout and nothing else.
# `test/kiln_cms/config/env_test.exs` checks all of them, not just this file.
alias KilnCMS.Config.Env

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kiln_cms start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
#
# `truthy?/1`, not `flag/2`: this is the one variable documented as "any truthy
# value", so a blank or unrecognized value must keep starting the server exactly
# as the generator's bare `if System.get_env(...)` did. It is also the one
# variable the generator's form got wrong in the dangerous direction —
# `PHX_SERVER=false` started the server anyway, because every string is truthy
# in Elixir. Nothing catches that: the release boots, runs migrations, answers
# `bin/kiln_cms rpc`, so the Docker healthcheck stays green, and it serves no
# HTTP at all.
if Env.truthy?("PHX_SERVER") do
  config :kiln_cms, KilnCMSWeb.Endpoint, server: true
end

config :kiln_cms, KilnCMSWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# ## How this file is organized (#1322)
#
# What follows used to be 1,523 lines in this one file. It is now a list of
# per-concern fragments under `config/runtime/`, evaluated in the exact order
# their blocks appeared here, so evaluation order — which is load-bearing —
# is unchanged. Three things depend on that order and would break quietly if a
# fragment moved:
#
#   * `:config_warnings` is a LIST built in evaluation order by
#     `KilnCMS.Config.Env`, and `test/kiln_cms/config/env_test.exs` asserts
#     that order. Moving a fragment reorders an operator's boot warnings.
#   * `Config` DEEP-MERGES successive `config` calls for the same key, so per
#     key the later write wins — `runtime/demo.exs` deliberately overrides the
#     mailer and federation settings written above it.
#   * `Env.take_collected/0` at the bottom DRAINS the collector, so every
#     fragment must be evaluated above it.
#
# A fragment is evaluated inline, in this same process, so its `config` calls
# merge exactly as they did when they were written here. What does NOT cross
# the boundary is a local VARIABLE: each fragment is a self-contained slice.
# The one value two fragments both need (the canonical `PHX_HOST`) therefore
# lives in `KilnCMS.Config.Host.canonical/0` rather than being derived twice.
#
# ## Why `Code.eval_file/1` and not `import_config/1`
#
# Because `import_config/1` raises here. Elixir evaluates this file with
# imports disabled — `mix run`/`mix test`/`mix phx.server` all go through
# `Mix.Tasks.App.Config`, which passes `imports: :disabled`, and the release
# config provider is the case the restriction was written for:
#
#     ** (RuntimeError) import_config/1 is not enabled for this configuration
#        file. Some configuration files do not allow importing other files as
#        they are often copied to external systems
#
# That reason is exactly right, and it is the thing to get right rather than
# to work around: `mix release` copies only `config/runtime.exs` into
# `releases/<vsn>/`. So the fragments are copied next to it by the `:steps`
# hook in `mix.exs` (which refuses to assemble a release without them), and
# the Dockerfile copies the directory into the build context. `__DIR__`
# resolves to `config/` under Mix and to `releases/<vsn>/` in a release, so
# one path expression serves both.

fragment = fn name ->
  path = Path.join([__DIR__, "runtime", name])

  unless File.regular?(path) do
    # Reachable only in a release assembled without the `:steps` hook in
    # mix.exs, or from an image whose Dockerfile does not COPY the directory.
    # Worth its own message: the bare File.Error names a path under
    # releases/<vsn>/ that exists nowhere in the source tree, which reads like
    # a corrupted release rather than a missing build step.
    raise """
    #{path} is missing.

    config/runtime.exs is a list of per-concern fragments (#1322) and this is
    one of them. A release must ship config/runtime/ alongside runtime.exs —
    see the `:steps` hook in mix.exs and the matching COPY in the Dockerfile.
    """
  end

  Code.eval_file(path)
end

fragment.("console.exs")
fragment.("observability.exs")
fragment.("cross_origin.exs")
fragment.("delivery.exs")
fragment.("media.exs")
fragment.("governance.exs")
fragment.("schedules.exs")
fragment.("feature_gates.exs")
fragment.("updates.exs")
fragment.("analytics.exs")

# Production-only. Each fragment holds the block it always had; the guard stays
# here so the whole production surface reads as one list.
if config_env() == :prod do
  fragment.("prod/database.exs")
  fragment.("prod/web.exs")
  fragment.("prod/sso.exs")
  fragment.("prod/backups.exs")
  fragment.("prod/storage.exs")
  fragment.("prod/search.exs")
  fragment.("prod/ai.exs")
  fragment.("prod/oembed.exs")
  fragment.("prod/mailer.exs")
end

fragment.("provenance_claims.exs")
fragment.("push.exs")

# Last before the warning flush, so it can override the mailer and federation
# blocks above it — see runtime/demo.exs.
fragment.("demo.exs")

# ── Boot-time config warnings ────────────────────────────────────────────────
#
# MUST STAY LAST. `KilnCMS.Config.Env` warns on stderr for a variable it cannot
# parse, and in a release that line reaches container stdout and nothing else —
# no Sentry, no OTel, no log sink — because config providers run before `Logger`
# exists (#634). `Env.take_collected/0` returns what this evaluation warned
# about, so `KilnCMS.Application` can replay it once observability is attached.
# It DRAINS (unlike the plain `collected/0` reader), so a process that evaluates
# this file twice — the test harness does — reports only that pass's reads.
#
# Anything calling `Env` *below* this line is warned about on stderr only, which
# is the failure mode #634 exists to close. `test/kiln_cms/config/env_test.exs`
# fails if that happens.
#
# Written unconditionally rather than `if warnings != []`: `Config` deep-merges,
# so skipping the empty case would leave a previous evaluation's list in place
# on the config-provider path.
config :kiln_cms, :config_warnings, Env.take_collected()
# Below the `Env.take_collected()` flush on purpose: nothing here goes through
# `Env` (these are plain strings, not flags), so there is no warning to
# collect, and sitting last means the block shifts no `config/runtime.exs:N`
# anchor in docs/environment-variables.md — which the docs gate checks.
# The test database's host and name — runtime config on purpose (#1392).
#
# Both come from environment variables that differ between the CI test
# shards (MIX_TEST_PARTITION is 1..N) and between local worktrees. Mix records
# the evaluated compile-time config in its build manifest and, when a config
# file is newer than that record, recompiles the whole app if the project's
# own values changed — so while these lived in config/test.exs, every shard
# that restored a `_build` another shard had saved found a different
# `database:` and recompiled all of it. Here they are read at boot instead:
# `mix test` and `mix ash.setup` both run `app.config` before touching the
# repo, so nothing that creates, migrates or connects to the database sees a
# difference. The rest of the Repo config stays in config/test.exs.
#
# "localhost" reaches a `services:` postgres from a job running directly on
# the runner. A job running inside a `container:` (the qpdf CI leg, #907) is
# on a separate Docker network where the service is only reachable by its
# service name instead, hence the override.
if config_env() == :test do
  config :kiln_cms, KilnCMS.Repo,
    hostname: System.get_env("POSTGRES_HOST", "localhost"),
    database: "kiln_cms_test#{System.get_env("MIX_TEST_PARTITION")}"
end
