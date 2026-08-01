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
  stdout — visible in `docker logs`, but never forwarded to Sentry. It is a
  boot-time line an operator has to look for, not an alert.

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
  previous build. That is why `config/test.exs`'s `KILN_STRICT_TEST` read stays
  a raw `System.get_env/1` comparison and must not be "finished off" to use
  this module — doing so breaks every clean build.
  """

  @true_values ~w(true 1 yes on)
  @false_values ~w(false 0 no off)

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

        :unrecognized
    end
  end
end
