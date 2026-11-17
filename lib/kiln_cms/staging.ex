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
  alias KilnCMS.Staging.Scrub

  # A throwaway database's name must contain one of these, so the scrub can't be
  # aimed at a production database called "kiln_prod" by accident. Override a
  # deliberately-named clone with `force?: true`.
  @ephemeral_markers ~w(staging preview ephemeral tmp scratch)

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
      paused: restart the application once the scrub is done. Only for
      re-scrubbing a node that is already a scrubbed clone, since jobs may
      have run before the pause.
    * `:shell` — 1-arity logger for human output (default `&IO.puts/1`).
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

    guard_live_oban!(shell, Keyword.get(opts, :allow_live?, false), opts)

    shell.("Scrubbing #{database}@#{host} …")
    summary = Scrub.run(admin_email: admin_email, admin_password: admin_password)
    report(shell, summary)
    warn_unlabelled(shell)
    summary
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
  Whether the Oban instance `name` is running and executing jobs (`testing:
  :disabled`). False when it is not started (a release `eval`) or is inert
  (`inert_oban_config/1`, the test suite).
  """
  @spec oban_live?(Oban.name()) :: boolean()
  def oban_live?(name \\ Oban) do
    # A release `eval` starts the repo alone: without Oban's registry,
    # `Oban.whereis/1` raises rather than answering nil.
    with registry when is_pid(registry) <- Process.whereis(Oban.Registry),
         pid when is_pid(pid) <- Oban.whereis(name) do
      Oban.config(name).testing == :disabled
    else
      _ -> false
    end
  end

  # `:oban_live?` in `opts` replaces the check, so a test can stand in for a
  # live node without starting a second, executing Oban.
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
        :ok = Oban.pause_all_queues(Oban)

        shell.(
          "Oban is live on this node: every queue is now paused. " <>
            "Restart the application after the scrub to resume them."
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
  # reported without a change here.
  defp report(shell, summary) do
    counts = summary |> Map.delete(:admin_provisioned) |> Enum.sort()

    labels =
      Enum.map(counts, fn {key, _} -> key |> Atom.to_string() |> String.replace("_", " ") end)

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
