defmodule KilnCMS.Config.Env do
  @moduledoc """
  One parser for the boolean environment variables `config/runtime.exs` reads.

  `runtime.exs` used to decide this per variable — five hand-rolled parsers in
  three different unrecognized-value semantics and two normalization styles,
  plus two bare `== "false"` equality checks on the SMTP flags: seven call
  sites, no two guaranteed to agree (#607). Two were wrong in a way nothing
  failed on: `DATABASE_SSL=True` silently gave the operator a **plaintext**
  Postgres connection (#606), and `VISUAL_EDITING_ENABLED=False` left the bridge
  on. Both defects are the same one — the value was matched raw, so any
  capitalization or stray whitespace missed and fell through to that site's idea
  of "not set".

  ## Semantics

  Values are trimmed and downcased before matching:

    * `true` / `1` / `yes` / `on` → `true`
    * `false` / `0` / `no` / `off` → `false`
    * unset, or set to the empty string (a common `FOO=` artifact of `.env`
      files and `docker run --env-file`) → not set
    * anything else → **not set, plus a warning on stderr**

  That last rule is the important one, and the reason this is a shared module
  rather than a one-line `in ~w(true 1)`. A misspelling is never *interpreted*
  in either direction: it keeps whatever the compiled config chose and says so
  loudly. So a typo cannot silently defeat `DATABASE_SSL`, `SMTP_TLS` or
  `SMTP_TLS_VERIFY`, all of which default to on — that is #606.

  Note the symmetric limitation, since "fail safe" is the wrong mental model
  here: this fails to the **default**, which is only the safe side when the
  default is. `KILN_AUDIT_ANCHOR_EVERY_WRITE` defaults to `false` and is the
  documented way to switch per-write signing *on*, so a typo there leaves it
  off; the stderr warning is the only signal. Conversely
  `VISUAL_EDITING_ENABLED` defaults to on, so a typo leaves the bridge exposed
  rather than shutting it. Neither is a regression — both previously did the
  same thing silently — but do not read this module as a guarantee that
  unparseable always means safe.

  The warning goes to `:standard_error` rather than `Logger`, because config
  providers run before `Logger` is available. In a release that means container
  stdout — visible in `docker logs`, but never forwarded to Sentry.

  So each unrecognized read is *also* recorded (see `collected/0`), and
  `config/runtime.exs` hands the accumulated list to `:kiln_cms,
  :config_warnings` on its way out. `KilnCMS.Application` replays it through
  `Logger.warning/1` once observability is attached, so the one signal an
  operator gets that a flag did not take effect reaches Sentry and every log
  sink rather than scrolling past in a deploy (#634).

  The stderr write stays regardless — it is the only thing available if the
  application never starts at all.

  > #### Not for secrets {: .warning}
  >
  > An unrecognized value is echoed to stderr via `inspect/1`. Only pass
  > variables that hold a flag. For a variable that carries a credential, see
  > `KilnCMS.Keys.Providers.Env`, which reads secrets and deliberately does not
  > log their values.

  ## Which function

  `flag/2` is for a variable whose absence has a definite meaning, and returns a
  boolean. `fetch/1` is for a variable that must only *override* config when the
  operator actually set it — writing nothing is meaningfully different from
  writing `false`, since the latter overrides a compiled default or a project
  overlay.

      iex> KilnCMS.Config.Env.flag("KILN_NO_SUCH_VAR", true)
      true

      iex> KilnCMS.Config.Env.fetch("KILN_NO_SUCH_VAR")
      :unset

  ## `runtime.exs` only — never a compile-time config file

  This is callable from `config/runtime.exs` because that file is evaluated
  *after* compilation, with the release's code paths loaded — the same reason
  `KilnCMSWeb.CORS.parse_env/1` can be called there. Being a real module also
  makes the parsing directly unit-testable instead of reachable only by
  evaluating `runtime.exs`.

  It is **not** callable from `config/config.exs`, `config/test.exs`,
  `config/dev.exs` or `config/e2e.exs`. Those are evaluated before
  `loadpaths`/`compile`, so no project module is on the code path — measured,
  not assumed: `Code.ensure_loaded?/1` on this module from `config/test.exs`
  returns `false` (`:non_existing`) even when the `.beam` already exists from a
  previous build. `config/test.exs`'s `KILN_STRICT_TEST` read (#646) can't
  "finish off" and call this module for that reason — doing so breaks every
  clean build — so it goes through the standalone `config/strict_test_flag.exs`
  instead, a `.exs` with the same spelling table but zero project dependencies,
  loaded via `Code.require_file/2`. `true_values/0`/`false_values/0` below
  exist so that snippet's copy can be checked against this module's, rather
  than trusted to stay in sync by hand.
  """

  require Logger

  @true_values ~w(true 1 yes on)
  @false_values ~w(false 0 no off)

  # Unrecognized reads accumulate here rather than in application env, because a
  # release's config provider computes runtime config in a boot VM and then
  # restarts the system — anything `Application.put_env/3` wrote during that pass
  # is gone by the time the real VM starts. What survives is the config the
  # provider *returns*, which is why the handoff is a `config` call at the end of
  # `runtime.exs` rather than a write from in here.
  #
  # The process dictionary is the right scope for that: `runtime.exs` is
  # evaluated in a single process, so one pass sees exactly its own reads. The
  # handful of callers that reach `flag/2` at request time instead
  # (`KilnCMS.Staging`) accumulate into their own short-lived process and are
  # never collected, which is the behaviour we want — those are already inside a
  # running system where `Logger` works.
  @collected_key {__MODULE__, :collected}

  @doc """
  The recognized "on" spellings, for `config/strict_test_flag.exs`'s sync test
  (#646) — that snippet cannot call this module (see "`runtime.exs` only"
  above), so it carries a literal copy instead; this is what keeps the copy
  honest.
  """
  @spec true_values() :: [String.t()]
  def true_values, do: @true_values

  @doc "The recognized \"off\" spellings — see `true_values/0`."
  @spec false_values() :: [String.t()]
  def false_values, do: @false_values

  @typedoc """
  The three outcomes of reading a flag: an operator-supplied boolean, nothing
  set, or something set that could not be understood (already warned about).
  """
  @type fetched :: {:ok, boolean()} | :unset | :unrecognized

  @doc """
  Reads `var` as a boolean, falling back to `default`.

  `default` is used both when the variable is unset and when its value could not
  be recognized — an unparseable value never flips a flag, it only warns.
  """
  @spec flag(String.t(), boolean()) :: boolean()
  def flag(var, default) when is_binary(var) and is_boolean(default) do
    case fetch(var) do
      {:ok, value} -> value
      _unset_or_unrecognized -> default
    end
  end

  @doc """
  Whether `var` is **present** and not set to a recognized "off" spelling.

  The permissive counterpart to `flag/2`, for a variable documented as "set to
  any truthy value" — `PHX_SERVER` is the only one, and it is the only flag here
  that should not go through `flag/2` or `fetch/1`.

  Presence is what enables. A blank `PHX_SERVER=` still starts the server, and
  so does an unrecognized value, exactly as the upstream Phoenix form
  (`if System.get_env("PHX_SERVER")`) did — an empty string is truthy in Elixir.
  Reading either as "do not serve HTTP" would take a release that boots, runs
  migrations and answers `bin/kiln_cms rpc` — so the container healthcheck stays
  green — and leave it serving nothing.

  The single behavioural change from upstream is that an explicit
  `false`/`0`/`no`/`off` now disables rather than enabling, which is the one
  reading no operator intends.

  Unrecognized values do not warn: every non-false value is meaningful here.

      iex> System.put_env("KILN_TRUTHY_DOCTEST", "please")
      iex> KilnCMS.Config.Env.truthy?("KILN_TRUTHY_DOCTEST")
      true

      iex> System.put_env("KILN_TRUTHY_DOCTEST", "OFF")
      iex> KilnCMS.Config.Env.truthy?("KILN_TRUTHY_DOCTEST")
      false
  """
  @spec truthy?(String.t()) :: boolean()
  def truthy?(var) when is_binary(var) do
    # Branches on `System.get_env/1` rather than on the normalized string, so
    # nil and "" stay distinguishable — collapsing them is precisely the bug
    # this function exists to avoid.
    case System.get_env(var) do
      nil -> false
      raw -> String.downcase(String.trim(raw)) not in @false_values
    end
  end

  @doc """
  Reads `var` as a boolean without supplying a default.

  Returns `{:ok, boolean}` only when the operator set a recognized value, so a
  caller can leave config untouched otherwise. `:unrecognized` has already been
  warned about by the time it is returned; callers that treat it exactly like
  `:unset` are doing the right thing.
  """
  @spec fetch(String.t()) :: fetched()
  def fetch(var) when is_binary(var) do
    raw = System.get_env(var, "")

    case raw |> String.trim() |> String.downcase() do
      "" ->
        :unset

      value when value in @true_values ->
        {:ok, true}

      value when value in @false_values ->
        {:ok, false}

      _other ->
        # `raw`, not the normalized form: the trimming and downcasing are
        # exactly what caused the mismatch, so reporting `"enabled"` when the
        # operator wrote `" Enabled "` hides the only clue they can act on —
        # they grep their compose file for the echoed string and find nothing.
        IO.warn(
          """
          #{var} is set to an unrecognized value (#{inspect(raw)}); keeping \
          the configured default. Use one of: #{Enum.join(@true_values, "/")}, \
          #{Enum.join(@false_values, "/")}.\
          """,
          []
        )

        record_unrecognized(var, raw)
        :unrecognized
    end
  end

  @doc """
  The unrecognized reads this process has made, in the order they happened.

  Values are safe to log: this module is flag-only by contract (see the
  "Not for secrets" note above). Do not generalize the replay to arbitrary
  variables without revisiting that.
  """
  @spec collected() :: [{String.t(), String.t()}]
  def collected, do: @collected_key |> Process.get([]) |> Enum.reverse()

  @doc """
  `collected/0`, and forgets it.

  This is the form `config/runtime.exs` uses, **last**, to hand the list to
  `:kiln_cms, :config_warnings` for `KilnCMS.Application` to replay through
  `Logger` once observability is up (#634). Ordering matters — a read below the
  handoff is warned about on stderr and nowhere else — so
  `test/kiln_cms/config/env_test.exs` pins that nothing calls this module there.

  Draining rather than merely reading, because a process can evaluate
  `runtime.exs` more than once: a release does it once, but `Config.Reader.read!/2`
  in the test harness runs in the calling process, so a second evaluation would
  otherwise inherit the first's warnings and report variables the operator never
  set on that pass.
  """
  @spec take_collected() :: [{String.t(), String.t()}]
  def take_collected do
    collected = collected()
    Process.delete(@collected_key)
    collected
  end

  @doc """
  Re-emits what `runtime.exs` collected, once the system is up, so a
  misconfigured flag reaches the places an operator actually watches (#634).

  Called once from `KilnCMS.Application.start/2`, after `setup_observability/0`.
  The stderr line `fetch/1` already wrote stays: it is the only thing available
  if the application never starts at all, so this is a second copy of the same
  fact, not a replacement.

  ## Two emissions, because `Logger` alone does not reach Sentry

  `Logger.warning/1` is what puts the line in front of a log collector — it is
  formatted, timestamped, and carried by whatever ships the application's output.

  It does **not** reach Sentry. The handler is attached with the library's
  defaults (`Sentry.LoggerHandler`: `level: :error`, `capture_log_messages:
  false`), so a `:warning` is dropped at the first filter in the handler's
  `handle_event/3`, and a bare string log with no `:crash_reason` metadata is
  ignored even above that level. Raising the handler's level globally would send
  Sentry every warning the application emits — a much larger change than this
  issue asked for — so the Sentry event is reported explicitly instead.

  `Sentry.capture_message/2` no-ops when no DSN is configured
  (`Sentry.Client.send_event/2` guards on `ensure_dsn_configured/0`), so this
  costs a deployment without Sentry nothing.

  Lives here rather than in `KilnCMS.Application` so the boot-time and
  after-boot wordings cannot drift, and so it is directly testable — an
  unexercised replay is the kind of thing that ships inert.
  """
  @spec replay_collected() :: :ok
  def replay_collected do
    for {var, raw} <- Application.get_env(:kiln_cms, :config_warnings, []) do
      Logger.warning(message_for(var, raw))
      report_to_sentry(var, raw)
    end

    :ok
  end

  defp message_for(var, raw) do
    "#{var} is set to an unrecognized value (#{inspect(raw)}); the configured default " <>
      "was kept, so this variable had no effect. Use one of: " <>
      "#{Enum.join(@true_values, "/")}, #{Enum.join(@false_values, "/")}."
  end

  # A stable message with the variable in `fingerprint`, so Sentry groups one
  # issue per variable rather than one per deployment — an operator wants "this
  # flag is still wrong", not a new issue each restart. The offending value goes
  # in `extra` for the same reason it is quoted on stderr: it is the only thing
  # they can act on. Safe to send — this module is flag-only by contract.
  defp report_to_sentry(var, raw) do
    _ =
      Sentry.capture_message(message_for(var, raw),
        level: :warning,
        fingerprint: ["kiln-config-warning", var],
        extra: %{variable: var, value: raw}
      )

    :ok
  end

  # Prepend + reverse in `collected/0`, so a boot reading dozens of flags does
  # not walk the list once per warning.
  defp record_unrecognized(var, raw),
    do: Process.put(@collected_key, [{var, raw} | Process.get(@collected_key, [])])
end
