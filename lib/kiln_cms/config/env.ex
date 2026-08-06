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
  stdout — visible in `docker logs`, but the config provider can't reach Sentry
  or a log sink. So each unrecognized read is also accumulated (see
  `warnings/0`), and `KilnCMS.Application` calls `replay_warnings/0` once the
  system is up to re-emit them — through `Logger` for the console and any OTel/log
  sink, and through `Sentry.capture_message/2` for Sentry, because the Sentry
  logger handler runs with its defaults and forwards crashes rather than plain
  warnings (#634). The stderr line stays regardless: it is the only thing left if
  the app never finishes starting.

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

  @true_values ~w(true 1 yes on)
  @false_values ~w(false 0 no off)

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

        record_warning(var, raw)
        :unrecognized
    end
  end

  # ── Boot-warning replay (#634) ─────────────────────────────────────────────

  # The `IO.warn` above is the only signal an operator gets that a flag didn't
  # take effect, and in a release it reaches container stdout only — never Sentry
  # or a log sink, because config providers run before `Logger` exists. So each
  # unrecognized read is also accumulated here for `KilnCMS.Application` to replay
  # through `Logger` once the system is up.
  #
  # `:persistent_term`, not application env: it is plain VM state, available both
  # in the config-provider context (where a provider's own config would not yet
  # be applied) and at application start, so it sidesteps every question about
  # whether a `put_env` from inside a provider survives the provider's own
  # `put_all_env`. Flag-only by contract (see the "Not for secrets" note), so the
  # accumulated raw values are safe to echo.
  @warnings_key {__MODULE__, :boot_warnings}

  defp record_warning(var, raw) do
    :persistent_term.put(@warnings_key, :persistent_term.get(@warnings_key, []) ++ [{var, raw}])
  end

  @doc """
  The unrecognized-value warnings accumulated by `fetch/1` (and thus `flag/2`)
  during config evaluation — `{var, raw_value}` in read order (#634).
  """
  @spec warnings() :: [{String.t(), String.t()}]
  def warnings, do: :persistent_term.get(@warnings_key, [])

  @doc "Drop the accumulated warnings (after replay, or between tests)."
  @spec clear_warnings() :: :ok
  def clear_warnings do
    _ = :persistent_term.erase(@warnings_key)
    :ok
  end

  @doc """
  Replay every accumulated warning where the boot-time `IO.warn` cannot reach —
  through `Logger.warning/1` for the console and any OTel/log sink, and through
  `Sentry.capture_message/2` for Sentry (whose logger handler forwards crashes,
  not plain warnings) — then clear them. Called once by `KilnCMS.Application`
  after the system is up. Returns the count replayed. The `IO.warn` is
  deliberately kept: it is the only thing left if the app never finishes
  starting.
  """
  @spec replay_warnings() :: non_neg_integer()
  def replay_warnings do
    require Logger

    accumulated = warnings()

    for {var, raw} <- accumulated do
      message =
        "#{var} was set to an unrecognized value (#{inspect(raw)}) at boot; the configured " <>
          "default was kept. See docs/environment-variables.md."

      # Logger reaches the console backend and any OTel/log sink. Sentry's
      # LoggerHandler is attached with its defaults (`capture_log_messages:
      # false`), so it forwards crashes but NOT plain `Logger.warning/1`, which
      # would leave the operator-facing point of #634 unmet — an operator watching
      # Sentry would still miss the misconfiguration. So the message is also sent
      # to Sentry explicitly; with no `SENTRY_DSN` this is a no-op, exactly like
      # every other capture in dev/test.
      Logger.warning(message)
      Sentry.capture_message(message, level: :warning)
    end

    clear_warnings()
    length(accumulated)
  end
end
