defmodule KilnCMS.Demo do
  @moduledoc """
  **Demo mode**: a public "try the editor" instance that returns to a known-good
  state on a schedule. Off unless explicitly enabled. See `docs/demo-mode.md`.

  A demo deployment is an ordinary Kiln with four differences:

    1. **It resets.** `reset/1` replaces the database with a *golden snapshot* —
       a `pg_dump` the operator captured once, after curating the demo content
       (`capture_golden!/1`) — then runs any migrations newer than the
       snapshot. `KILN_DEMO_RESET_CRON` schedules it (hourly by default);
       `reset!/1` runs one by hand.
    2. **Nothing a visitor does can delete a file.** Storage deletes are
       deferred to the reset, which removes only files the golden state doesn't
       reference (`KilnCMS.Demo.Blobs`).
    3. **Mail and federation are inert.** `config/runtime.exs` swaps the mailer
       for `Swoosh.Adapters.Logger` and switches federation off, because on a
       public demo anyone can trigger them.
    4. **The shared account's credentials are fixed.** A non-admin can't change
       a password, two-factor or passkeys (`locks_credentials?/1`), because
       every visitor signs in as the same account.

  ## Hard off by default

  Enabling takes `KILN_DEMO_RESET=confirm` — a sentinel word, not a boolean, the
  same convention as `KILN_STAGING_SCRUB`. Even then every reset re-checks that
  the database, the served host and the golden snapshot all look like a demo
  (`KilnCMS.Demo.Guard`), at run time, every time — not once at boot.

  ## The order of a reset

      guard ─ read golden ─ render SQL ─ note current media keys
        │
        ▼
      quiesce  (gate mounts + collab, close documents, pause + drain Oban, evict)
        │
        ▼
      restore  (wipe + golden, ONE transaction — failure changes nothing)
        │
        ▼
      reconnect pool ─ evict again ─ flush caches ─ migrate ─ reap media ─ flush
        │
        ▼
      resume   (always, even after a failure)

  Everything up to the restore can refuse without side effects beyond a paused
  queue that is resumed. The restore either commits or rolls back. After it
  commits, a failed migration is reported loudly and left for the next reset
  (or the next deploy's `migrate`) — the schema is then the snapshot's, which
  is older but consistent.
  """

  require Logger

  alias KilnCMS.Backups
  alias KilnCMS.Demo.Blobs
  alias KilnCMS.Demo.Guard
  alias KilnCMS.Demo.LiveState
  alias KilnCMS.Demo.Restore
  alias KilnCMS.Repo

  @type reason ::
          Guard.reason()
          | {:missing_tool, String.t()}
          | {:golden_missing, Path.t()}
          | {:golden_unreadable, String.t()}
          | {:restore_failed, String.t()}
          | {:dump_failed, String.t()}
          | {:migrate_failed, String.t()}

  @type summary :: %{
          golden: Path.t(),
          source_database: String.t(),
          migrations_applied: non_neg_integer(),
          blobs_deleted: non_neg_integer(),
          blob_failures: non_neg_integer(),
          users_evicted: non_neg_integer(),
          documents_closed: non_neg_integer(),
          jobs_still_running: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  @tools ~w(pg_dump pg_restore psql)

  # -- configuration -----------------------------------------------------------

  @doc """
  Whether demo mode is on — `KILN_DEMO_RESET=confirm` at boot. Only the literal
  `true` in config counts, so a stray truthy value can't switch it on.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: config(:enabled, false) == true

  @doc """
  Whether demo mode refuses `actor` a change to its own credentials — password,
  two-factor, passkeys (`KilnCMS.Accounts.Validations.NotDemoSharedAccount`).

  True for every non-admin while demo mode is on: on a demo they are all the
  one shared account, and a credential one visitor changed would lock the rest
  out until the next reset. Admins are never refused (the operator curates the
  demo as one), and neither is `nil` — a system call with no actor.
  """
  @spec locks_credentials?(term()) :: boolean()
  def locks_credentials?(nil), do: false
  def locks_credentials?(%{role: :admin}), do: false
  def locks_credentials?(_actor), do: enabled?()

  @doc """
  Where the golden snapshot lives: `KILN_DEMO_GOLDEN_PATH`, else `demo/golden.dump`
  under `BACKUP_DIR` — writable by the release user and already a volume on a
  deployment that keeps backups.
  """
  @spec golden_path() :: Path.t()
  def golden_path, do: config(:golden_path) || Path.join([Backups.dir(), "demo", "golden.dump"])

  @doc "The directory holding the golden snapshot and the reset's working files."
  @spec dir() :: Path.t()
  def dir, do: Path.dirname(golden_path())

  @doc "The reset schedule, or `nil` when demo mode is off or unscheduled."
  @spec schedule() :: String.t() | nil
  def schedule do
    with true <- enabled?(),
         cron when is_binary(cron) <- Application.get_env(:kiln_cms, :demo_reset_cron) do
      String.trim(cron)
    else
      _ -> nil
    end
  end

  @doc """
  When the next scheduled reset is due, or `nil` — demo mode off, no schedule,
  or one `Oban.Cron.Expression` can't place (`@reboot`, `false`).

  For the banner that tells visitors their changes are temporary.
  """
  @spec next_reset_at(DateTime.t()) :: DateTime.t() | nil
  def next_reset_at(now \\ DateTime.utc_now()) do
    with cron when is_binary(cron) <- schedule(),
         {:ok, expression} <- Oban.Cron.Expression.parse(cron),
         %DateTime{} = at <- Oban.Cron.Expression.next_at(expression, now) do
      at
    else
      _ -> nil
    end
  end

  @doc "Whether a reset is running on this node. See `KilnCMS.Demo.LiveState`."
  @spec resetting?() :: boolean()
  defdelegate resetting?, to: LiveState

  @doc """
  What the guard judges: this deployment's Repo target, the URL the tools would
  connect with, and the served host.

  The host is read from application config rather than the endpoint so a
  release `eval` — where the endpoint isn't running — sees the same value.
  """
  @spec target() :: Guard.target()
  def target do
    {repo_host, repo_database} = Repo.target()

    %{
      enabled?: enabled?(),
      repo_host: repo_host,
      repo_database: repo_database,
      url: Backups.database_url(),
      site_host:
        :kiln_cms
        |> Application.get_env(KilnCMSWeb.Endpoint, [])
        |> Keyword.get(:url, [])
        |> Keyword.get(:host)
    }
  end

  # -- operations --------------------------------------------------------------

  @doc """
  Resets the demo to the golden snapshot. See the moduledoc for the order.

  ## Options

    * `:live?` — quiesce this running node around the restore (default `true`).
      `KilnCMS.Release.reset_demo/0` passes `false`: under `bin/kiln_cms eval`
      there are no sockets, queues or caches in the process to quiesce.
    * `:job_id` — the calling Oban job, excluded from the drain.
  """
  @spec reset(keyword()) :: {:ok, summary()} | {:error, reason()}
  def reset(opts \\ []) do
    started = System.monotonic_time(:millisecond)
    target = target()

    with :ok <- Guard.check(target),
         :ok <- tools(),
         {:ok, golden} <- Restore.read_golden(golden_path()),
         :ok <- Guard.check_golden_source(golden.source_database),
         {:ok, work} <- Restore.prepare(golden, Path.join(dir(), "work")) do
      Logger.info("Demo reset starting from #{golden.path} (#{golden.source_database})")

      try do
        restore(golden, work, target.url, opts)
      after
        Restore.cleanup(work)
      end
      |> finish(golden, started)
    end
  end

  @doc """
  `reset/1` for an operator: prints a summary through `:shell` (default
  `IO.puts/1`) and returns it, or raises with the reason. The manual reset on a
  running node:

      /app/bin/kiln_cms rpc 'KilnCMS.Demo.reset!()'
  """
  @spec reset!(keyword()) :: summary()
  def reset!(opts \\ []) do
    shell = Keyword.get(opts, :shell, &IO.puts/1)
    shell.("Target database: #{target_label()}")

    case reset(opts) do
      {:ok, summary} ->
        shell.("""
        Demo reset complete in #{summary.duration_ms} ms:
          golden snapshot:     #{summary.golden} (from #{summary.source_database})
          migrations applied:  #{summary.migrations_applied}
          media files removed: #{summary.blobs_deleted} (#{summary.blob_failures} failed)
          users signed out:    #{summary.users_evicted}\
        """)

        summary

      {:error, reason} ->
        raise explain(reason)
    end
  end

  @doc """
  Captures the current database as the golden snapshot, replacing any previous
  one. Curate the demo content on the demo instance itself, then:

      /app/bin/kiln_cms rpc 'KilnCMS.Demo.capture_golden!()'

  Guarded like a reset — it only ever snapshots a demo database — and written
  `.partial`-then-rename, so a failed capture leaves the previous snapshot in
  place. Returns the path.
  """
  @spec capture_golden!(keyword()) :: Path.t()
  def capture_golden!(opts \\ []) do
    shell = Keyword.get(opts, :shell, &IO.puts/1)
    target = target()
    path = golden_path()

    with :ok <- Guard.check(target),
         :ok <- tools(),
         :ok <- Restore.dump(target.url, path) do
      shell.("Golden snapshot of #{target_label()} written to #{path}")
      path
    else
      {:error, reason} -> raise explain(reason)
    end
  end

  @doc """
  Whether `reason` is a refusal (nothing was attempted) rather than a failure.
  The worker cancels on the first and errors on the second.
  """
  @spec refusal?(reason()) :: boolean()
  def refusal?({kind, _detail}) when kind in [:restore_failed, :migrate_failed, :dump_failed],
    do: false

  def refusal?(_reason), do: true

  @doc "A sentence an operator can act on, for each `reason/0`."
  @spec explain(reason()) :: String.t()
  def explain(:disabled),
    do:
      "Demo mode is off. Set KILN_DEMO_RESET=confirm on the demo deployment (only `confirm` enables it)."

  def explain({:database_not_demo, database}),
    do:
      "Refusing to reset #{inspect(database)}: a demo database's name must contain \"demo\". " <>
        "This check has no override."

  def explain({:host_not_demo, host}),
    do:
      "Refusing to reset a deployment served at #{inspect(host)}: PHX_HOST must contain \"demo\" " <>
        "(or be localhost). This check has no override."

  def explain(:no_database_url),
    do: "Refusing to reset: no database URL for pg_restore/psql. Set DATABASE_URL."

  def explain({:url_mismatch, {url_host, url_db}, {repo_host, repo_db}}),
    do:
      "Refusing to reset: the tools would connect to #{url_db}@#{url_host} but the application " <>
        "uses #{repo_db}@#{repo_host}. Check BACKUP_DATABASE_URL."

  def explain({:golden_not_demo, source}),
    do:
      "Refusing to restore a golden snapshot dumped from #{inspect(source)}: it must come from a " <>
        "database named like a demo, so a production backup can never be published here."

  def explain({:missing_tool, tool}),
    do:
      "Refusing to reset: #{tool} is not installed (the release image ships postgresql-client-17)."

  def explain({:golden_missing, path}),
    do:
      "No golden snapshot at #{path}. Curate the demo content, then run " <>
        "`bin/kiln_cms rpc 'KilnCMS.Demo.capture_golden!()'`."

  def explain({:golden_unreadable, detail}), do: "The golden snapshot is unreadable: #{detail}"

  def explain({:restore_failed, detail}),
    do: "The restore failed and was rolled back — the demo is unchanged: #{detail}"

  def explain({:dump_failed, detail}), do: "Capturing the golden snapshot failed: #{detail}"

  def explain({:migrate_failed, detail}),
    do:
      "The golden snapshot was restored, but migrating it failed — the schema is the " <>
        "snapshot's until the next reset or deploy: #{detail}"

  # -- internals ---------------------------------------------------------------

  defp restore(golden, work, url, opts) do
    live? = Keyword.get(opts, :live?, true)
    dirty_keys = MapSet.new(keys_or_empty(Blobs.referenced_keys()))
    quiesced = if live?, do: LiveState.quiesce(job_id: opts[:job_id]), else: nil

    try do
      with :ok <- Restore.run(work, url) do
        users_evicted = after_restore(live?, quiesced)
        migrated = migrate()
        blobs = reap(dirty_keys)
        if live?, do: KilnCMS.Cache.flush_delivery()

        with {:ok, versions} <- migrated do
          {:ok,
           %{
             source_database: golden.source_database,
             migrations_applied: length(versions),
             blobs_deleted: blobs.deleted,
             blob_failures: blobs.failed,
             users_evicted: users_evicted,
             documents_closed: if(quiesced, do: quiesced.documents_closed, else: 0),
             jobs_still_running: if(quiesced, do: quiesced.jobs_still_running, else: 0)
           }}
        end
      end
    after
      if live?, do: LiveState.resume()
    end
  end

  # Every pooled connection planned its prepared statements, and cached type
  # OIDs, against tables and types the restore just replaced. Recycling them
  # is cheaper than finding out which queries notice.
  defp after_restore(false, _quiesced) do
    Ecto.Adapters.SQL.disconnect_all(Repo, 0)
    0
  end

  defp after_restore(true, quiesced) do
    Ecto.Adapters.SQL.disconnect_all(Repo, 0)
    users = LiveState.after_restore(quiesced.users)
    KilnCMS.Cache.flush_delivery()
    users
  end

  defp migrate do
    {:ok, Ecto.Migrator.run(Repo, :up, all: true)}
  rescue
    error -> {:error, {:migrate_failed, Exception.message(error)}}
  end

  # A failed golden read reaps NOTHING: subtracting an empty golden set would
  # make every file the demo has ever referenced a candidate, golden ones
  # included. Deferred deletes stay logged for the next reset.
  defp reap(dirty_keys) do
    case Blobs.referenced_keys() do
      {:ok, golden_keys} ->
        Blobs.reap(dirty_keys, MapSet.new(golden_keys))

      {:error, error} ->
        Logger.error(
          "Demo reset skipped media cleanup — couldn't read golden keys: #{inspect(error)}"
        )

        %{deleted: 0, failed: 0}
    end
  end

  defp keys_or_empty({:ok, keys}), do: keys

  defp keys_or_empty({:error, error}) do
    Logger.warning("Demo reset couldn't read pre-reset media keys: #{inspect(error)}")
    []
  end

  defp finish({:ok, summary}, golden, started) do
    summary =
      Map.merge(summary, %{
        golden: golden.path,
        duration_ms: System.monotonic_time(:millisecond) - started
      })

    Logger.info("Demo reset complete: #{inspect(summary)}")
    {:ok, summary}
  end

  defp finish({:error, reason}, _golden, _started) do
    Logger.error("Demo reset failed: #{explain(reason)}")
    {:error, reason}
  end

  defp tools do
    case Enum.find(@tools, &is_nil(System.find_executable(&1))) do
      nil -> :ok
      missing -> {:error, {:missing_tool, missing}}
    end
  end

  defp target_label do
    {host, database} = Repo.target()
    "#{database}@#{host}"
  end

  defp config(key, default \\ nil) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
