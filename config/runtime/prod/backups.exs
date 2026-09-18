import Config

alias KilnCMS.Config.Env

# A fragment of config/runtime.exs, evaluated by it inside its
# `config_env() == :prod` guard — nothing here applies in dev or test. It sits
# at the position this block always occupied; evaluation ORDER matters, see the
# header of config/runtime.exs before moving anything.

# In-app backups (#484). Every one of these mirrors an environment variable
# `scripts/backup.sh` already reads, and by the same name — the cron path and
# the app path are two front doors to one backup directory, and an operator
# who configured the script should not have to configure this separately.
#
# BACKUP_ENABLED=false turns the in-app path off (the panel then explains
# why) without touching the cron one.

# Blank counts as UNSET, the convention this file already follows for
# DATABASE_SSL_CACERTFILE. `MEDIA_DIR=` is a routine `.env`/compose artifact,
# and reading it as set gave `media_dir: ""` — `File.dir?("")` is false, so
# every in-app backup failed, while `backup.sh`'s `[ -n … ]` correctly
# skipped media and succeeded. `BACKUP_DIR=` was worse: `""` is truthy in
# Elixir, so backups would land in a relative `db/` under the release's cwd.
backup_env = fn var ->
  case System.get_env(var) do
    nil -> nil
    raw -> if String.trim(raw) == "", do: nil, else: raw
  end
end

# `Env.flag/2` for the boolean and `Env.positive_integer/1` for the counts —
# one shared parser each, see this file's header. The counts used to be a
# hand-rolled `Integer.parse` here and in three other places (#1009). An
# unparseable or non-positive value keeps the default and warns rather than
# being interpreted: `BACKUP_KEEP_DAYS=0` read literally would delete every
# backup it had just taken.
backup_int = fn var, default ->
  case Env.positive_integer(var) do
    {:ok, parsed} -> parsed
    _unset_or_unrecognized -> default
  end
end

backup_opts =
  [
    enabled: Env.flag("BACKUP_ENABLED", true),
    dir: backup_env.("BACKUP_DIR") || "/var/backups/kiln",
    keep_days: backup_int.("BACKUP_KEEP_DAYS", 14),
    stale_after_hours: backup_int.("BACKUP_STALE_AFTER_HOURS", 36)
  ]

# Same variable the script uses, so the app path copies off-site too — a
# backup that exists only on the machine being backed up is not a backup of
# that machine.
backup_opts =
  case backup_env.("BACKUP_RCLONE_REMOTE") do
    nil -> backup_opts
    remote -> Keyword.put(backup_opts, :rclone_remote, remote)
  end

# Escape hatch for a connection `KilnCMS.Backups.database_url/0` can't
# derive — a unix-socket repo, or one whose `DATABASE_URL` reaches the
# database through something `pg_dump` can't use. Ordinary deployments never
# set it: `DATABASE_URL` is already the first thing consulted.
backup_opts =
  case backup_env.("BACKUP_DATABASE_URL") do
    nil -> backup_opts
    url -> Keyword.put(backup_opts, :database_url, url)
  end

# Unset on an S3 deployment, deliberately — the bucket is backed up
# provider-side, and tarring the wrong directory yields an archive that
# looks like a media backup and restores nothing.
backup_opts =
  case backup_env.("MEDIA_DIR") do
    nil -> backup_opts
    media_dir -> Keyword.put(backup_opts, :media_dir, media_dir)
  end

config :kiln_cms, KilnCMS.Backups, backup_opts
