defmodule KilnCMS.Config.Report do
  @moduledoc """
  Where a configuration warning reaches an operator, once the system is up.

  `KilnCMS.Config.Env` already owns this for the values it parses itself —
  `replay_collected/0` emits a `Logger.warning/1` *and* an explicit
  `Sentry.capture_message/2`, because `Sentry.LoggerHandler` is attached with
  the library's defaults (`level: :error`, `capture_log_messages: false`), so
  a plain `Logger.warning/1` never becomes a Sentry event (#634). That was one
  module solving it for **grammar** failures — an env var set to something
  `Env` cannot parse.

  It does not generalize to **solvability** failures — a value that parses
  fine but turns out not to work once the application can actually check it:
  no mailer adapter configured in prod, strict tenancy off with more than one
  org, a brand colour with no AA-clearing token, an AI feature pointed at a
  provider whose subprocessor status nobody has reviewed. None of those are
  parse errors, and none of them can be caught at config-provider time — they
  need the database, the running application, or a resolved third-party
  answer. `KilnCMS.Application`'s five `warn_if_*` boot checks and
  `KilnCMS.Branding.css_variables/1`'s AA check are all this shape, and before
  this module existed each used a bare `Logger.warning/1` — invisible to
  Sentry for the exact reason #634 fixed for `Env`, just not fixed *there*
  (#1126).

  One place that knows how a configuration-shaped warning reaches an
  operator, instead of six (now seven, counting `Env`) that each reach half
  way.

  ## Not for secrets

  Same contract as `Env`: `message` reaches `Logger` *and* Sentry, so it must
  never carry a credential — an adapter name, a boolean, a hex colour, a
  provider slug are all fine; an API key or a database URL is not. Callers
  that need to report on a secret's *presence* (not its value) already do —
  see `warn_if_no_mailer_in_prod/0`, which names the adapter, never a key.
  """
  require Logger

  @doc """
  Emits `message` through both channels an operator might be watching:
  `Logger.warning/1` (whatever ships the deployment's logs) and
  `Sentry.capture_message/2`, grouped by `source` so a standing
  misconfiguration is one Sentry issue across every restart rather than one
  per restart.

  `source` is a short, stable identifier for the fingerprint — an env var
  name (`"TENANT_STRICT_HOST"`) or a slug for a warning not tied to one
  variable (`"branding_contrast"`) — never interpolated into `message`
  itself, so it stays stable even if the message's wording changes.

  `extra` rides along in the Sentry event for whatever context helps
  triage (e.g. the offending value) — same reasoning `Env.replay_collected/0`
  already applies: safe to attach only when it holds no secret.

  `Sentry.capture_message/2` no-ops when no DSN is configured, so this costs
  a deployment without Sentry nothing.
  """
  @spec warn(String.t(), String.t(), map()) :: :ok
  def warn(source, message, extra \\ %{})
      when is_binary(source) and is_binary(message) and is_map(extra) do
    Logger.warning(message)

    _ =
      Sentry.capture_message(message,
        level: :warning,
        fingerprint: ["kiln-config-warning", source],
        extra: extra
      )

    :ok
  end

  @doc """
  Run `fun`, taking `default` if it cannot answer (#1288).

  The other half of a solvability warning: these checks need the database, and
  a check that *breaks* when the database cannot answer is a worse failure than
  the one it describes. `KilnCMSWeb.Tenant.org_count/0` says so in as many
  words, and `KilnCMS.Governance.Chain.any_history_anchors?/0` cites it as the
  model — so this is the one place that decides what "cannot answer" covers,
  rather than two `rescue` clauses that each decide half of it.

  Both of them used a bare `rescue`, which is exactly half. A `Repo` read is a
  `:gen_server.call` into the pool: a refused connection or a `:queue_timeout`
  *raises* `DBConnection.ConnectionError` and was covered, but a call into a
  pool process that is not alive — crashed, or still restarting under its
  supervisor after repeated connect failures — **exits**, and `rescue` does not
  catch exits. "The database is not up yet" and "the pool is restarting" are
  the same operational moment, and only one of them was handled. Both callers
  run inside `KilnCMS.Application.start/2`, so the exit took the boot down
  instead of dropping the advisory.

  Deliberately narrow in two ways. It catches `:exit` and not `:throw` — a
  throw out of a database read is a programmer error somewhere, and a guard
  that quietly turned it into `default` would bury it. And it takes a `default`
  from the caller rather than assuming one: `org_count/0`'s is `:unknown`,
  which its `gap?/1` then judges, and `false` would be a different (wrong)
  answer there.

  Not a general-purpose "try this and shrug" — it is for a read whose only
  consumer is an advisory. Anything a request or a write depends on should
  fail loudly.
  """
  @spec probe(default, (-> result)) :: default | result when default: term(), result: term()
  def probe(default, fun) when is_function(fun, 0) do
    fun.()
  rescue
    _error -> default
  catch
    :exit, _reason -> default
  end
end
