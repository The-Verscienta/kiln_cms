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

  alias KilnCMS.Backups.Manifest

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
