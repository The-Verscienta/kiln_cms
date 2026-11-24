defmodule KilnCMS.Staging do
  @moduledoc """
  Operator-facing entry point for standing up an **ephemeral staging /
  preview environment** from a production clone. See
  `docs/staging-environments.md`.

  The one public call is `scrub!/1`, which turns a freshly-restored copy of
  production into a PII-free, secret-free environment. It is guarded so a
  mistyped `DATABASE_URL` can't scrub production, then delegates the actual work
  to `KilnCMS.Staging.Scrub`.

  Callable from Mix (`mix kiln.staging.scrub`, which boots Oban inert:
  `inert_oban_config/1`), from a release before serving
  (`KilnCMS.Release.scrub_staging/0` via `bin/kiln_cms eval`, which starts no
  Oban at all), or against a running node (`bin/kiln_cms rpc`). A running node
  whose Oban executes jobs is refused unless `allow_live?: true` is passed: its
  queues could run the clone's copy of production's jobs (mail, webhooks,
  federation deliveries) before the scrub deletes them.
  """

  alias KilnCMS.Repo
  alias KilnCMS.Staging.PluginScrub
  alias KilnCMS.Staging.Scrub

  # A throwaway database's name must contain one of these, so the scrub can't be
  # aimed at a production database called "kiln_prod" by accident. Override a
  # deliberately-named clone with `force?: true`.
  @ephemeral_markers ~w(staging preview ephemeral tmp scratch)

  @doc false
  # scripts/staging.sh carries a copy of the list; its test compares them.
  @spec ephemeral_markers() :: [String.t()]
  def ephemeral_markers, do: @ephemeral_markers

  @doc """
  Scrub the currently-connected database into a safe staging environment.

  Refuses unless the caller has clearly opted in. Prints the target and a
  summary through `:shell` (default `IO.puts/1`) and returns the summary map.

  ## Options

    * `:confirm?` — must be truthy, or set `KILN_STAGING_SCRUB=confirm`. Without
      it the target is printed and nothing is changed.
    * `:force?` — skip the ephemeral-name check (or `KILN_STAGING_FORCE=true`;
      accepts any spelling `KilnCMS.Config.Env` recognizes).
    * `:admin_email` / `:admin_password` — provision one usable admin. Default to
      `STAGING_ADMIN_EMAIL` / `STAGING_ADMIN_PASSWORD`.
    * `:allow_live?` — scrub even though this node's Oban is executing jobs
      (`oban_live?/1`). Every queue is paused first, cluster-wide, and stays
      paused: restart the application, on every node, once the scrub is
      done. A restart is also what drops production's content-signing key
      from each other node's cache: the scrub can only clear this one's.
      Only for
      re-scrubbing a node that is already a scrubbed clone, since jobs may
      have run before the pause.
    * `:shell` — 1-arity logger for human output (default `&IO.puts/1`).
    * `:plugins` / `:ash_domains` — passed to `KilnCMS.Staging.Scrub.run/1`;
      default to the installed plugins and `config :kiln_cms, :ash_domains`.
      The scrub refuses, having changed nothing, while one of their tables
      has no `c:Kiln.Plugin.staging_scrub/0` entry.
  """
  @spec scrub!(keyword()) :: Scrub.summary()
  def scrub!(opts \\ []) do
    shell = Keyword.get(opts, :shell, &IO.puts/1)
    {host, database} = Repo.target()

    # KILN_STAGING_SCRUB is a sentinel word, not a boolean — typing `true` must
    # not confirm a destructive scrub. KILN_STAGING_FORCE *is* a boolean, so it
    # goes through the shared spelling table (#606/#607): it used to accept only
    # the literal `1`, so `KILN_STAGING_FORCE=true` read as "not forced" — the
    # same you-get-the-opposite-of-what-you-typed defect, failing loudly here
    # rather than silently. It only relaxes the ephemeral-name check; the
    # sentinel above is still required either way.
    confirmed? = Keyword.get(opts, :confirm?) || env_sentinel?("KILN_STAGING_SCRUB", "confirm")
    forced? = Keyword.get(opts, :force?) || KilnCMS.Config.Env.flag("KILN_STAGING_FORCE", false)

    admin_email = opts[:admin_email] || System.get_env("STAGING_ADMIN_EMAIL")
    admin_password = opts[:admin_password] || System.get_env("STAGING_ADMIN_PASSWORD")

    shell.("Target database: #{database}@#{host}")

    unless confirmed? do
      raise """
      Refusing to scrub without explicit confirmation.

      This deletes personal data and outbound secrets from #{database}@#{host}.
      Confirm you mean this database (NOT production) with `--yes`
      (mix) or `KILN_STAGING_SCRUB=confirm` (release).
      """
    end

    unless forced? or ephemeral_name?(database) do
      raise """
      Refusing to scrub #{inspect(database)}: its name doesn't look ephemeral.

      A staging database name should contain one of: #{Enum.join(@ephemeral_markers, ", ")}.
      If this really is a throwaway clone, re-run with `--force`
      (mix) or `KILN_STAGING_FORCE=true` (release).
      """
    end

    # Before the queues are paused: a refusal here must leave a live node as
    # it found it. `Scrub.run/1` checks again, so no caller can skip it.
    _steps = PluginScrub.plan!(Keyword.take(opts, [:plugins, :ash_domains]))

    guard_live_oban!(shell, Keyword.get(opts, :allow_live?, false), opts)

    shell.("Scrubbing #{database}@#{host} …")

    summary =
      opts
      |> Keyword.take([:plugins, :ash_domains])
      |> Keyword.merge(admin_email: admin_email, admin_password: admin_password)
      |> Scrub.run()

    report(shell, summary)

    warn_mounted_provenance_key(
      shell,
      Keyword.get_lazy(opts, :provenance_key_mounted?, &KilnCMS.Keys.provenance_key_mounted?/0)
    )

    warn_unlabelled(shell)
    summary
  end

  # The scrub removes the generated signing key (#2974), but a mounted one
  # (`KILN_PROVENANCE_PRIVATE_KEY` / `KILN_PROVENANCE_KEY_FILE`) wins over it
  # and lives in the environment, out of the scrub's reach. One resolving here
  # usually means this is production's environment (a release `eval` on the
  # production host): say so, because the staging application must not be
  # given the same. `:provenance_key_mounted?` in `opts` stands in for the
  # check in tests.
  defp warn_mounted_provenance_key(_shell, false), do: :ok

  defp warn_mounted_provenance_key(shell, true) do
    shell.("""

    Warning: a provenance signing key is mounted in this environment
    (KILN_PROVENANCE_PRIVATE_KEY or KILN_PROVENANCE_KEY_FILE). A mounted key
    wins over the database, so a staging application given production's signs
    as production whatever the scrub removed. Do not give the application
    serving this clone production's KILN_PROVENANCE_* variables: leave them
    unset (it generates a key of its own) or mount a staging key.\
    """)
  end

  @doc """
  The Oban config `mix kiln.staging.scrub` boots with: `config` with
  `testing: :manual`, the mode the test suite runs in. Oban starts, so
  AshOban and anything that inserts a job still work, but no queue executes a
  job and no plugin (Cron, Pruner, Lifeline) runs.

  `queues: false, plugins: false` would read the same, but config keyword
  lists deep-merge (#608) and AshOban requires the Cron plugin.
  """
  @spec inert_oban_config(keyword()) :: keyword()
  def inert_oban_config(config), do: Keyword.put(config, :testing, :manual)

  @doc """
  The `KilnCMS.Backups` config `mix kiln.staging.scrub` boots with:
  `config` with the backup heartbeat off, so the scrub's process neither
  sweeps the cloned backup lock nor beats as a node of production's cluster.
  """
  @spec inert_backups_config(keyword()) :: keyword()
  def inert_backups_config(config), do: Keyword.put(config, :heartbeat?, false)

  @doc """
  Whether the Oban instance `name` is running and can execute jobs: any
  `testing` mode but `:manual` (`:inline` runs a job the moment it is
  inserted). False when it is not started (a release `eval`) or is inert
  (`inert_oban_config/1`, the test suite).
  """
  @spec oban_live?(Oban.name()) :: boolean()
  def oban_live?(name \\ Oban) do
    # A release `eval` starts the repo alone: without Oban's registry,
    # `Oban.whereis/1` raises rather than answering nil.
    with registry when is_pid(registry) <- Process.whereis(Oban.Registry),
         pid when is_pid(pid) <- Oban.whereis(name) do
      Oban.config(name).testing != :manual
    else
      _ -> false
    end
  end

  # `:oban_live?` in `opts` replaces the check, so a test can stand in for a
  # live node without starting a second, executing Oban; `:pause_queues`
  # replaces the pause, so a test can see whether it happened.
  defp guard_live_oban!(shell, allow_live?, opts) do
    live? = Keyword.get_lazy(opts, :oban_live?, fn -> oban_live?(Oban) end)

    cond do
      not live? ->
        :ok

      not allow_live? ->
        raise """
        Refusing to scrub from a node whose Oban queues are running.

        Its queues can execute the clone's copy of production's jobs (mail,
        webhooks, federation deliveries) before the scrub deletes them. Run
        the scrub before serving instead: `mix kiln.staging.scrub` or
        `bin/kiln_cms eval "KilnCMS.Release.scrub_staging()"`. To re-scrub a
        node that is already a scrubbed clone, pass `allow_live?: true`.
        """

      true ->
        :ok = Keyword.get(opts, :pause_queues, fn -> Oban.pause_all_queues(Oban) end).()

        shell.(
          "Oban is live on this node: every queue is now paused. " <>
            "Restart the application after the scrub, on every node, to resume them " <>
            "and to drop production's signing key from each node's cache."
        )
    end
  end

  # A scrub is the moment a database is *proven* to be a clone, and a clone keeps
  # production's content and branding — so the console serving it is byte-for-byte
  # identical to the real one until someone labels it (#469).
  #
  # Printed unconditionally, and phrased about the *served deployment* rather
  # than about this process, because the two are usually not the same one: the
  # documented flow (`scripts/staging.sh`, the Coolify recipe) runs the scrub as
  # a throwaway `bin/kiln_cms eval` against a remote DATABASE_URL, so a laptop's
  # own KILN_ENV_LABEL would suppress the reminder while the served application
  # stayed unlabelled — and an unlabelled laptop would nag an operator who had
  # already set it. Neither reading is worth having; a short unconditional line
  # is.
  defp warn_unlabelled(shell) do
    shell.("""

    Before serving this clone: set KILN_ENV_LABEL on the application that will
    serve it (e.g. "staging"), and optionally KILN_ENV_COLOR — one of
    #{Enum.join(KilnCMS.Environment.tones(), ", ")}. Without it the console is
    indistinguishable from production's. Leave both unset in production.\
    """)
  end

  # Every count in the summary, by key, so a purge added to `Scrub` is
  # reported without a change here. A plugin's tables sort after the core's
  # (a tuple after every atom).
  defp report(shell, summary) do
    counts = summary |> Map.delete(:admin_provisioned) |> Enum.sort()

    labels = Enum.map(counts, fn {key, _} -> report_label(key) end)

    width = labels |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end) |> max(13)

    lines =
      counts
      |> Enum.zip(labels)
      |> Enum.map_join("\n", fn {{_key, count}, label} ->
        "  " <> String.pad_trailing(label <> ":", width + 2) <> to_string(count)
      end)

    shell.("Scrub complete:\n" <> lines)

    admin = String.pad_trailing("staging admin:", width + 2)

    case summary.admin_provisioned do
      nil ->
        shell.("  #{admin}NONE — set STAGING_ADMIN_EMAIL / STAGING_ADMIN_PASSWORD to sign in.")

      email ->
        shell.("  #{admin}#{email} (role :admin, pre-confirmed)")
    end
  end

  @doc false
  # The report line's label for a summary key. Public for its test.
  @spec report_label(atom() | KilnCMS.Staging.PluginScrub.key()) :: String.t()
  def report_label({:plugin, plugin_name, table}), do: "#{plugin_name} plugin, #{table}"
  def report_label(key) when is_atom(key), do: key |> Atom.to_string() |> String.replace("_", " ")

  defp ephemeral_name?(database) do
    down = String.downcase(database)
    Enum.any?(@ephemeral_markers, &String.contains?(down, &1))
  end

  defp env_sentinel?(var, expected) do
    case System.get_env(var) do
      nil -> false
      value -> String.downcase(String.trim(value)) == expected
    end
  end
end
