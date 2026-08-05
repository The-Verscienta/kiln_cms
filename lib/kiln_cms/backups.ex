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

  @doc "The database this deployment backs up. `nil` when nothing is configured."
  @spec database_url() :: String.t() | nil
  def database_url do
    case config(:database_url) do
      url when is_binary(url) and url != "" ->
        url

      _ ->
        # Fall back to the Repo's own configuration rather than requiring the
        # operator to state the connection twice — and rebuild a URL from it,
        # because `pg_dump` takes a connection string, not a keyword list.
        repo_url()
    end
  end

  defp repo_url do
    config = KilnCMS.Repo.config()

    case Keyword.get(config, :url) do
      url when is_binary(url) and url != "" -> url
      _ -> build_url(config)
    end
  end

  defp build_url(config) do
    with database when is_binary(database) <- Keyword.get(config, :database),
         username when is_binary(username) <- Keyword.get(config, :username) do
      host = Keyword.get(config, :hostname, "localhost")
      port = Keyword.get(config, :port, 5432)
      password = Keyword.get(config, :password)

      auth = if password, do: "#{encode(username)}:#{encode(password)}", else: encode(username)

      "postgres://#{auth}@#{host}:#{port}/#{database}"
    else
      _ -> nil
    end
  end

  defp encode(value), do: URI.encode_www_form(to_string(value))

  defp config(key, default \\ nil) do
    :kiln_cms |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
