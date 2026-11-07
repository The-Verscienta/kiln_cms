defmodule KilnCMS.Backups do
  @moduledoc """
  In-app backups (#484): what the last one was, and running a new one.

  Kiln's backups have always been `scripts/backup.sh` on cron — solid for a
  self-hoster with shell access, and completely invisible to everyone else.
  Two ecosystems say that isn't enough (Akeeba is Joomla's most-installed
  extension outright, UpdraftPlus is top-10 on WordPress), and the thing they
  are really selling is not a novel dump format. It is *knowing*.

  So the shape here is visibility first:

    * `status/0` reads a **manifest** written by whichever path last ran, so
      the console can say when the last backup was, how big it was, and
      whether it verified — including for a cron run this application never
      saw.
    * `run/1` performs one, from the app, on its own Oban queue.

  ## The shell scripts stay canonical

  `scripts/backup.sh` and `scripts/restore.sh` remain the documented ops path,
  and this module deliberately produces **byte-identical artifacts**: the same
  `pg_dump --format=custom --no-owner --no-privileges`, the same
  `kiln-db-<stamp>.dump` / `kiln-media-<stamp>.tar.gz` names under the same
  `db/` and `media/` directories, the same `.partial`-then-rename discipline,
  the same `pg_restore --list` verification. `scripts/restore.sh` restores an
  app-made backup and this module reports on a cron-made one, because there is
  one format and one directory layout, not two.

  That constraint is why `run/1` shells out to `pg_dump` rather than
  implementing a dump in Elixir. A hand-rolled logical export would be a
  second format with a second restore procedure, and the restore path is
  exactly where a backup system earns its keep.

  ## Restore is not here

  Deliberately. In-app restore is where Akeeba-class complexity and risk live:
  it means taking the application down, replacing the database underneath a
  running BEAM, and having a credible answer when it fails halfway. The
  documented drill in `docs/backups.md` is the supported path.
  """

  use Ash.Domain

  alias KilnCMS.Backups.Manifest

  resources do
    resource KilnCMS.Backups.Run do
      # Every write is the `:backups` system actor's (`system/0`): the worker,
      # the importer and `reconcile_stale_runs/0`. The history page reads
      # `run_history` as a platform admin.
      define :start_run, action: :start
      define :skip_run, action: :skip
      define :record_run_progress, action: :record_progress
      define :finish_run, action: :finish
      define :fail_run, action: :fail
      define :import_run, action: :import
      define :list_runs, action: :read
      define :run_history, action: :history
      define :get_run, action: :read, get_by: [:id]
      define :get_run_by_stamp, action: :by_stamp, args: [:stamp], not_found_error?: false
      define :list_running_runs, action: :running
    end
  end

  # See `with_actor/2`.
  @actor_override {__MODULE__, :actor_override}

  @doc """
  The actor the backup pipeline runs as (#2217): the worker that records a run,
  the importer that turns cron-made backups into rows, and
  `reconcile_stale_runs/0`.

  A `KilnCMS.SystemActor` labelled `:backups`, admitted by name on
  `KilnCMS.Backups.Run` for exactly the actions those callers use (see
  `docs/policy-matrix.md`, "The system actor") rather than `authorize?: false`.
  """
  @spec system() :: KilnCMS.SystemActor.t() | nil
  def system do
    case Process.get(@actor_override, :unset) do
      :unset -> KilnCMS.SystemActor.new(:backups)
      actor -> actor
    end
  end

  @doc false
  # Test seam, as `KilnCMS.Billing.with_actor/2`: run `fun` with `system/0`
  # answering `actor` in this process, so a test can take the grant away and
  # prove the importer and the stale sweep fail CLOSED. Process-local; nothing
  # on a request path calls it.
  @spec with_actor(term(), (-> result)) :: result when result: term()
  def with_actor(actor, fun) do
    previous = Process.get(@actor_override, :unset)
    Process.put(@actor_override, actor)

    try do
      fun.()
    after
      if previous == :unset,
        do: Process.delete(@actor_override),
        else: Process.put(@actor_override, previous)
    end
  end

  # How long past the worker's own timeout a `running` run may sit before it is
  # presumed dead: slack for a slow final write, and for a node whose clock
  # lags the one that started the run.
  @stale_grace_minutes 15

  @doc """
  Fail every `running` run that can no longer be running (#2217), and return how
  many.

  **Time-based, not Oban-state-based**: `Worker.run/1` may be called from a
  console with no job behind it, so a run is stale when it started more than
  `Worker.timeout/1` plus #{@stale_grace_minutes} minutes before `now`, whatever
  Oban says. The job was killed or the node stopped; the run says so.

  Reads and writes as `system/0` and fails closed: a revoked grant raises
  instead of reporting "nothing stale". Callers on a request or job tail wrap it.
  """
  @spec reconcile_stale_runs(DateTime.t()) :: non_neg_integer()
  def reconcile_stale_runs(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -stale_after_ms(), :millisecond)

    # One stale row failing to update must not strand the rest as `running`.
    for run <- list_running_runs!(actor: system(), authorize_with: :error),
        DateTime.compare(run.started_at, cutoff) == :lt,
        match?(
          {:ok, _},
          fail_run(
            run,
            %{error: "Interrupted: the job was killed or the node stopped"},
            actor: system()
          )
        ) do
      run
    end
    |> length()
  end

  defp stale_after_ms do
    KilnCMS.Backups.Worker.timeout(nil) + :timer.minutes(@stale_grace_minutes)
  end

  @type status :: %{
          configured?: boolean(),
          available?: boolean(),
          manifest: Manifest.t() | nil,
          stale?: boolean(),
          reason: atom() | nil
        }

  @doc """
  Where backups are written. Mirrors `scripts/backup.sh`'s `BACKUP_DIR`,
  including its default, so both paths land in the same place without an
  operator configuring anything twice.
  """
  @spec dir() :: Path.t()
  def dir, do: config(:dir, "/var/backups/kiln")

  @doc """
  The uploads root to archive, or `nil`.

  `nil` is the correct answer on an S3 deployment: the bucket is backed up
  provider-side, and tarring a directory that doesn't hold the media would
  produce an archive that looks like a backup and isn't. Mirrors the script's
  `MEDIA_DIR`, which is unset for the same reason.
  """
  @spec media_dir() :: Path.t() | nil
  def media_dir, do: config(:media_dir, nil)

  @doc """
  The rclone remote to copy each backup to, or `nil` — the script's
  `BACKUP_RCLONE_REMOTE`.

  Not optional in spirit: a backup that only exists on the machine being
  backed up is not a backup of that machine. It is `nil`-able only because
  plenty of deployments handle off-siting outside Kiln entirely.
  """
  @spec rclone_remote() :: String.t() | nil
  def rclone_remote, do: config(:rclone_remote, nil)

  @doc "Local retention in days — the script's `BACKUP_KEEP_DAYS`."
  @spec keep_days() :: pos_integer()
  def keep_days, do: config(:keep_days, 14)

  @doc """
  How old the newest backup may be before the console calls it stale.

  Deliberately longer than a daily cadence: a warning that fires because a
  nightly job ran at 03:20 instead of 03:17 is one an admin learns to ignore.
  """
  @spec stale_after_hours() :: pos_integer()
  def stale_after_hours, do: config(:stale_after_hours, 36)

  @doc """
  Whether running a backup **from the app** is possible here.

  Three things have to be true, and they fail independently, so the reason is
  returned rather than a bare boolean — "backups are off" and "pg_dump isn't
  installed in this image" need completely different responses from an admin.
  """
  @spec availability() :: :ok | {:error, atom()}
  def availability do
    cond do
      not config(:enabled, true) -> {:error, :disabled}
      is_nil(database_url()) -> {:error, :no_database_url}
      is_nil(System.find_executable("pg_dump")) -> {:error, :no_pg_dump}
      is_nil(System.find_executable("pg_restore")) -> {:error, :no_pg_restore}
      true -> :ok
    end
  end

  @doc """
  Everything the console needs to render the backup panel.

  Never raises and never returns `nil` for the whole thing: an unreadable or
  absent manifest is a *state* worth showing ("no backup has ever run here"),
  not an error page.
  """
  @spec status() :: status()
  def status do
    availability = availability()
    manifest = Manifest.read(dir())

    %{
      configured?: not match?({:error, :disabled}, availability),
      available?: availability == :ok,
      # NOT `with({:error, r} <- availability, do: r)` — `with` returns the
      # non-matching value, so a healthy deployment would report its reason as
      # `:ok` and the panel would render "ok" as though it were a fault.
      reason: reason(availability),
      manifest: manifest,
      stale?: stale?(manifest)
    }
  end

  defp reason({:error, reason}), do: reason
  defp reason(_ok), do: nil

  @doc """
  Whether the newest backup is older than `stale_after_hours/0`.

  A missing manifest is **stale**, not fine. "Nothing has ever run" is the
  most alarming state this can be in, and defaulting it to green is how a
  deployment goes a year without a backup and nobody notices.
  """
  @spec stale?(Manifest.t() | nil) :: boolean()
  def stale?(nil), do: true

  def stale?(%Manifest{finished_at: nil}), do: true

  def stale?(%Manifest{finished_at: finished_at}) do
    DateTime.diff(DateTime.utc_now(), finished_at, :hour) >= stale_after_hours()
  end

  @doc """
  Enqueue a backup. Returns `{:error, reason}` when `availability/0` says this
  deployment can't run one, so the caller can explain rather than queue a job
  that is certain to fail.
  """
  @spec enqueue(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(opts \\ []) do
    with :ok <- availability() do
      %{"trigger" => to_string(Keyword.get(opts, :trigger, :manual))}
      |> KilnCMS.Backups.Worker.new()
      |> Oban.insert()
    end
  end

  @doc """
  The connection string this deployment backs up. `nil` when none can be
  determined, which `availability/0` reports rather than guessing.

  Three sources, in order of trustworthiness:

    1. an explicit `:database_url` config (the escape hatch for anything the
       other two get wrong);
    2. `DATABASE_URL` from the environment — what production actually sets,
       and the *original* string, complete with its query parameters;
    3. a URL rebuilt from `KilnCMS.Repo.config/0`.

  The environment is consulted before the Repo deliberately.
  Ecto's repo supervisor **pops** `:url` and merges the parsed fields back, so
  `Repo.config/0` never contains it — the original string is simply not
  recoverable from there, and rebuilding one is lossy: it drops the query
  string (`?sslmode=require`) and has to re-encode a password Ecto already
  decoded. Rebuilding is the fallback, not the plan.
  """
  @spec database_url() :: String.t() | nil
  def database_url do
    presence(config(:database_url)) || matching_env_url() || repo_url()
  end

  # `DATABASE_URL` is preferred over a rebuild — but ONLY when it describes the
  # database this application is actually connected to.
  #
  # In production the two are the same string (`runtime.exs` sets the Repo's
  # `url:` from it), and the env var is the better source: it is the original,
  # complete with the query parameters a rebuild drops. Elsewhere they can
  # disagree — `config/test.exs` configures discrete fields while a stale
  # `DATABASE_URL` lingers in the shell — and backing up whatever that stale
  # value points at, rather than the database being served, is the worst
  # possible way to be wrong about a backup.
  defp matching_env_url do
    with url when is_binary(url) <- presence(System.get_env("DATABASE_URL")),
         %URI{path: "/" <> database} <- URI.parse(url),
         ^database <- to_string(KilnCMS.Repo.config()[:database]) do
      url
    else
      _ -> nil
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp repo_url do
    config = KilnCMS.Repo.config()

    with database when is_binary(database) <- Keyword.get(config, :database),
         host when is_binary(host) <- Keyword.get(config, :hostname) do
      "postgres://#{userinfo(config)}#{host}:#{Keyword.get(config, :port, 5432)}/#{database}"
    else
      # No hostname means a unix-socket repo, which has no TCP URL to build —
      # and inventing `localhost` would point `pg_dump` at a different server
      # that may not exist, or none. An honest `nil`: `availability/0` reports
      # `:no_database_url` and the operator sets `BACKUP_DATABASE_URL`.
      #
      # A missing USERNAME is fine by contrast — `userinfo/1` omits it and
      # libpq falls back to `PGUSER`/the current user, which is exactly what a
      # peer-auth deployment wants.
      _ -> nil
    end
  end

  # Percent-encoding, NOT form encoding. `URI.encode_www_form/1` turns a space
  # into `+`, which libpq reads literally — so a password containing a space
  # authenticates as `p+ss` and every backup fails on a deployment that is
  # otherwise working perfectly.
  defp userinfo(config) do
    case Keyword.get(config, :username) do
      username when is_binary(username) ->
        case Keyword.get(config, :password) do
          password when is_binary(password) -> "#{encode(username)}:#{encode(password)}@"
          _ -> "#{encode(username)}@"
        end

      _ ->
        ""
    end
  end

  defp encode(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  defp config(key, default \\ nil) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
