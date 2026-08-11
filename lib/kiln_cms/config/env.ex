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

  # Upper bound for `positive_integer/1` (#1091). 2³¹-1: not a claim about what
  # a sensible retention or word-rate is, but a backstop against a mistyped
  # digit — Elixir integers are arbitrary-precision, so without it
  # `BACKUP_KEEP_DAYS=144444444444444` parses and is honoured.
  @max_integer 2_147_483_647

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

  @typedoc """
  What a rejected value was being read *as*, so `replay_collected/0` can tell
  the operator what to write instead. Recorded at the point of the failed parse
  — nothing downstream can recover it from the raw string.

  `{:one_of, spellings}` carries the allowed list rather than a pre-rendered
  sentence, so the advice cannot drift from the list the reader actually
  checked against. `{:expected, phrase}` is the escape hatch for a shape this
  module has no reader for — see `record_unusable/3`.
  """
  @type expectation ::
          :boolean | :positive_integer | {:one_of, [String.t()]} | {:expected, String.t()}

  @typedoc """
  One unrecognized read: the variable, exactly what the operator typed, and what
  it was being read as.
  """
  @type collected_warning :: {String.t(), String.t(), expectation()}

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
  Reads `var` as a **positive integer** without supplying a default (#1009).

  Same contract as `fetch/1`, for the same reason: `{:ok, n}` only when the
  operator set a usable value, so a caller can leave config untouched otherwise,
  and an unusable one is warned about *and recorded* so it reaches the Sentry
  replay rather than only container stdout.

  `config/runtime.exs` had hand-rolled this four times —
  `KILN_READING_TIME_WPM`, `KILN_EXPERIMENTS_STICKY_DAYS`,
  `KILN_ANALYTICS_LOW_COUNT_THRESHOLD` and the `BACKUP_*` counts — each with its
  own `IO.warn`, which is exactly the drift `fetch/1` exists to prevent for
  booleans. A fifth copy would have been a fifth chance to get "unparseable means
  the default, not a crash" wrong.

  **Positive**, not merely non-negative: every count this reads is a rate, a
  window or a retention, and zero is the value that reads as "do it never" or
  "delete everything" rather than as "unset".

  ## Bounded above, too (#1091)

  Elixir integers are arbitrary-precision, so without a ceiling a *digit* slip
  is accepted where a *letter* slip warns: `BACKUP_KEEP_DAYS=144444444444444` —
  a fat-fingered `14` — parses cleanly and silently becomes a four-billion-year
  retention. That is the one class this module still interpreted, against its
  own thesis that an unusable value must never be guessed at.

  The bound is `#{@max_integer}` (2³¹-1). It is arbitrary in the sense that any
  bound would be, but it is not a judgement about what a *sensible* value is —
  every real value for every variable this reads is smaller by orders of
  magnitude, so what it actually catches is a typo, which is the failure that
  happens. Anything genuinely needing a larger count wants its own reader with a
  range it can justify, not a wider blanket here.

      iex> System.put_env("KILN_INT_DOCTEST", "230")
      iex> KilnCMS.Config.Env.positive_integer("KILN_INT_DOCTEST")
      {:ok, 230}

      iex> System.put_env("KILN_INT_DOCTEST", "0")
      iex> KilnCMS.Config.Env.positive_integer("KILN_INT_DOCTEST")
      :unrecognized

      iex> System.put_env("KILN_INT_DOCTEST", "144444444444444")
      iex> KilnCMS.Config.Env.positive_integer("KILN_INT_DOCTEST")
      :unrecognized

      iex> System.delete_env("KILN_INT_DOCTEST")
      iex> KilnCMS.Config.Env.positive_integer("KILN_INT_DOCTEST")
      :unset
  """
  @spec positive_integer(String.t()) :: {:ok, pos_integer()} | :unset | :unrecognized
  def positive_integer(var) when is_binary(var) do
    raw = System.get_env(var, "")

    case raw |> String.trim() |> Integer.parse() do
      {parsed, ""} when parsed > 0 and parsed <= @max_integer ->
        {:ok, parsed}

      # Blank and unusable land in the same clause because `Integer.parse/1`
      # cannot tell them apart — `blank_or_bad/2` splits them.
      _other ->
        blank_or_bad(var, raw)
    end
  end

  # Blank — including whitespace-only — is `:unset`, exactly as in `fetch/1`.
  # `BACKUP_KEEP_DAYS=` in a compose file is how an operator writes "leave this
  # alone", and warning about it would be noise on every boot.
  defp blank_or_bad(var, raw) do
    if String.trim(raw) == "" do
      :unset
    else
      # `raw`, not the trimmed form — same reasoning as `fetch/1`: reporting
      # `"12"` when the operator wrote `" 12 "` hides the only clue they can
      # act on.
      IO.warn(
        "#{var} is set to #{inspect(raw)}, which is not a positive integer " <>
          "up to #{@max_integer}; keeping the configured default.",
        []
      )

      record_unrecognized(var, raw, :positive_integer)
      :unrecognized
    end
  end

  @doc """
  Reads `var` as one of `allowed`, trimmed and downcased (#912).

  The enum counterpart of `fetch/1` and `positive_integer/1`, with the same
  three-way contract. `allowed` is checked against and *carried into* the
  collected warning, so the "use one of…" advice an operator eventually reads
  is generated from the list the value was actually rejected against — a
  hand-written phrase beside the check is free to drift from it.

  `KILN_PROVENANCE_AI_DISCLOSURE` is the caller, and it is the reason this is a
  reader rather than a bare warning: the value rides into a **signed**
  provenance claim, so an operator who misspells it ships the compiled default
  in every manifest a consumer verifies. Before this it warned with a plain
  `IO.warn/1`, which in a release reaches container stdout and nothing else —
  the gap #634 closed for flags and left open here.

      iex> System.put_env("KILN_ENUM_DOCTEST", " Human ")
      iex> KilnCMS.Config.Env.one_of("KILN_ENUM_DOCTEST", ~w(human ai_assisted))
      {:ok, "human"}

      iex> System.delete_env("KILN_ENUM_DOCTEST")
      iex> KilnCMS.Config.Env.one_of("KILN_ENUM_DOCTEST", ~w(human ai_assisted))
      :unset
  """
  @spec one_of(String.t(), [String.t()]) :: {:ok, String.t()} | :unset | :unrecognized
  def one_of(var, allowed) when is_binary(var) and is_list(allowed) do
    raw = System.get_env(var, "")

    case raw |> String.trim() |> String.downcase() do
      "" ->
        :unset

      value ->
        if value in allowed do
          {:ok, value}
        else
          # `raw`, not the normalized form — `fetch/1`'s reasoning: the trimming
          # and downcasing are candidate explanations for the mismatch, so
          # echoing the normalized string hands back the one spelling that is
          # not in the operator's compose file.
          IO.warn(
            "#{var} is set to an unrecognized value (#{inspect(raw)}); keeping the " <>
              "configured default. #{advice({:one_of, allowed})}",
            []
          )

          record_unrecognized(var, raw, {:one_of, allowed})
          :unrecognized
        end
    end
  end

  @doc """
  Warns about, and collects, a value this module has no reader for (#912).

  The collector without a parser. `expected` completes the sentence "Expected …"
  — a phrase, not a sentence: `"a comma-separated list of PEM file paths"`.

  Two callers, and they earn the exception by having nothing in common — which
  is the point: neither shape generalizes, so a reader for either would have
  exactly one user.

    * `KILN_PROVENANCE_RETIRED_KEY_FILES` is a path list whose failure mode is
      "parsed to no paths at all". Left as a bare `IO.warn/1` it was stderr-only
      on a value that decides which retired keys still verify — a typo silently
      deregisters every one of them, which is the failure the variable exists to
      prevent.
    * `BRAND_PRIMARY_COLOR` is a hex grammar validated by
      `KilnCMS.CMS.Validations.BrandTokens.normalize_color/1`, the same
      validator the editor-managed row uses. Its rejection used to be a
      `Logger.warning` inside `KilnCMS.Branding`, which never reaches Sentry
      (#1089).

  Always returns `:unrecognized`, so a `case`/`cond` branch can end on it.

  Reach for a real reader first — `fetch/1`, `positive_integer/1`, `one_of/2`.
  A **third** caller is the signal that some shape here wants a reader of its
  own rather than a third hand-written phrase; `expected` is a free string, so
  nothing stops it drifting from what the caller actually checked.
  """
  @spec record_unusable(String.t(), String.t(), String.t()) :: :unrecognized
  def record_unusable(var, raw, expected)
      when is_binary(var) and is_binary(raw) and is_binary(expected) do
    IO.warn(
      "#{var} is set to an unrecognized value (#{inspect(raw)}); keeping the " <>
        "configured default. #{advice({:expected, expected})}",
      []
    )

    record_unrecognized(var, raw, {:expected, expected})
    :unrecognized
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

        record_unrecognized(var, raw, :boolean)
        :unrecognized
    end
  end

  @doc """
  The unrecognized reads this process has made, in the order they happened.

  Values are safe to log: this module reads **flags and counts** only (see the
  "Not for secrets" note above). #1009 widened it from flags to counts, and that
  was the question to answer first — a rejected boolean and a rejected
  positive-integer are both operator-typed configuration with no credential
  shape, so echoing them back is what makes the warning actionable. Do not
  generalize the replay past that without revisiting it: the moment this module
  reads a value that *could* be a secret, `collected/0` stops being safe to log.
  """
  @spec collected() :: [collected_warning()]
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
  @spec take_collected() :: [collected_warning()]
  def take_collected do
    collected = collected()
    Process.delete(@collected_key)
    collected
  end

  @doc """
  Re-emits what `runtime.exs` collected, once the system is up, so a
  misconfigured flag reaches the places an operator actually watches (#634).

  Called once from KilnCMS.Application's `start/2`, after `setup_observability/0`.
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
  (Sentry's `send_event` guards on a configured DSN), so this
  costs a deployment without Sentry nothing.

  Lives here rather than in `KilnCMS.Application` so the boot-time and
  after-boot wordings cannot drift, and so it is directly testable — an
  unexercised replay is the kind of thing that ships inert.
  """
  @spec replay_collected() :: :ok
  def replay_collected do
    for warning <- Application.get_env(:kiln_cms, :config_warnings, []) do
      {var, raw, expected} = normalize(warning)
      Logger.warning(message_for(var, raw, expected))
      report_to_sentry(var, raw, expected)
    end

    :ok
  end

  # A `for` comprehension filters out what its pattern does not match, so a
  # two-element entry — the shape this list had before #1009 — would be dropped
  # in silence. A warning that disappears without trace is the exact failure
  # this module exists to prevent, so the old shape is matched rather than left
  # to fall through, and anything else is reported as itself.
  defp normalize({var, raw, expected}), do: {var, raw, expected}
  defp normalize({var, raw}), do: {var, raw, :boolean}
  defp normalize(other), do: {inspect(other), "", :unknown}

  defp message_for(var, raw, expected) do
    "#{var} is set to an unrecognized value (#{inspect(raw)}); the configured default " <>
      "was kept, so this variable had no effect. " <> advice(expected)
  end

  # The advice has to match what the variable actually is. Before #1009 this
  # module read booleans only, so one hardcoded spelling list was correct; a
  # count replayed with "Use one of: true/1/yes/on" would send the operator to
  # fix the one thing that was never wrong.
  defp advice(:boolean),
    do: "Use one of: #{Enum.join(@true_values, "/")}, #{Enum.join(@false_values, "/")}."

  # Names the ceiling as well as the floor (#1091): an operator who typed one
  # digit too many is told the bound rather than left to infer that a number
  # they can see is a number was somehow not one.
  defp advice(:positive_integer), do: "Use a positive integer up to #{@max_integer}."

  defp advice({:one_of, allowed}), do: "Use one of: #{Enum.join(allowed, "/")}."

  defp advice({:expected, phrase}), do: "Expected #{phrase}."

  defp advice(:unknown),
    do: "The collected warning had an unrecognized shape; see KilnCMS.Config.Env."

  # A stable message with the variable in `fingerprint`, so Sentry groups one
  # issue per variable rather than one per deployment — an operator wants "this
  # flag is still wrong", not a new issue each restart. The offending value goes
  # in `extra` for the same reason it is quoted on stderr: it is the only thing
  # they can act on. Safe to send — this module reads flags and counts only.
  defp report_to_sentry(var, raw, expected) do
    _ =
      Sentry.capture_message(message_for(var, raw, expected),
        level: :warning,
        fingerprint: ["kiln-config-warning", var],
        extra: %{variable: var, value: raw}
      )

    :ok
  end

  # Prepend + reverse in `collected/0`, so a boot reading dozens of flags does
  # not walk the list once per warning.
  defp record_unrecognized(var, raw, expected),
    do: Process.put(@collected_key, [{var, raw, expected} | Process.get(@collected_key, [])])
end
