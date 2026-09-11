defmodule KilnCMS.Demo.Restore do
  @moduledoc """
  Replaces a demo database's contents with a golden `pg_dump` — atomically. See
  `docs/demo-mode.md`.

  ## One transaction, wipe included

  The golden archive is rendered to plain SQL (`pg_restore --file`) and applied
  with `psql --single-transaction`, preceded by a wipe script in the *same*
  transaction. Either the demo becomes the golden state, or nothing happened:
  a restore that fails halfway — a corrupt archive, a lock that never came, a
  disk that filled — rolls the wipe back with it, and visitors keep the
  (messy, working) demo they had rather than an empty database.

  ## Why a wipe, and not `pg_restore --clean`

  `--clean` drops only the objects *in the archive*. A golden snapshot is taken
  once and outlives upgrades, so the live database routinely has tables the
  archive has never heard of — every migration since. `--clean` would leave
  those in place, the restored `schema_migrations` would list their migrations
  as pending, and the `migrate` that follows would fail on `CREATE TABLE` of a
  table that already exists. The wipe drops everything in `public` instead, so
  "restore, then migrate" works for a snapshot of any age.

  ## Extensions are left alone

  The wipe skips every object an extension owns, and the archive's `EXTENSION`
  entries are filtered out of the restore. `vector` is not a trusted extension
  on every build, so dropping and re-creating it could need a superuser the
  demo's role doesn't have — and there is nothing to gain: the extension
  already exists in the demo database, created by the migrations that made it.
  Keeping it also keeps its type OIDs stable for the pooled connections that
  cached them.

  ## Data that is never restored

  `TABLE DATA` for #{inspect(~w(tokens oban_jobs oban_peers))} is filtered out,
  leaving those tables empty:

    * `tokens` — a snapshot carries whatever sessions existed when it was taken,
      the operator's own admin session among them. Restoring them would
      resurrect those sessions at every reset. Empty instead: everyone signs in
      again, which is also what should happen after a reset.
    * `oban_jobs` / `oban_peers` — jobs queued or leadership held at capture
      time, which would otherwise re-run against the restored data hours or
      months later.
  """

  alias KilnCMS.Backups.Worker

  @excluded_data ~w(tokens oban_jobs oban_peers)

  @typedoc "What `read_golden/1` learned from an archive's table of contents."
  @type golden :: %{path: Path.t(), source_database: String.t() | nil, listing: String.t()}

  @typedoc "The files `prepare/2` wrote, which `run/2` executes."
  @type work :: %{dir: Path.t(), wipe: Path.t(), restore: Path.t()}

  # Everything in `public` that no extension owns: relations first (CASCADE
  # takes their triggers, defaults and owned sequences), then routines, then
  # user-defined types. `IF EXISTS` because a CASCADE can already have removed a
  # later row of the same loop.
  #
  # `lock_timeout` so a reset queued behind a long-running query fails — and
  # rolls back — instead of holding its half-acquired locks indefinitely. The
  # restore script resets it to 0 after this, by which point every lock is held.
  @wipe_sql """
  SET LOCAL lock_timeout = '30s';
  SET LOCAL search_path = public, pg_catalog;

  DO $kiln_demo_wipe$
  DECLARE
    obj record;
  BEGIN
    FOR obj IN
      SELECT c.relkind, format('%I.%I', n.nspname, c.relname) AS name
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
        AND NOT c.relispartition
        AND NOT EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e'
        )
    LOOP
      EXECUTE format(
        CASE obj.relkind
          WHEN 'v' THEN 'DROP VIEW IF EXISTS %s CASCADE'
          WHEN 'm' THEN 'DROP MATERIALIZED VIEW IF EXISTS %s CASCADE'
          WHEN 'f' THEN 'DROP FOREIGN TABLE IF EXISTS %s CASCADE'
          WHEN 'S' THEN 'DROP SEQUENCE IF EXISTS %s CASCADE'
          ELSE 'DROP TABLE IF EXISTS %s CASCADE'
        END,
        obj.name
      );
    END LOOP;

    FOR obj IN
      SELECT format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) AS name
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND NOT EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e'
        )
    LOOP
      EXECUTE format('DROP ROUTINE IF EXISTS %s CASCADE', obj.name);
    END LOOP;

    FOR obj IN
      SELECT format('%I.%I', n.nspname, t.typname) AS name
      FROM pg_type t
      JOIN pg_namespace n ON n.oid = t.typnamespace
      WHERE n.nspname = 'public'
        AND t.typtype IN ('e', 'd', 'r', 'c')
        AND (t.typtype <> 'c' OR EXISTS (
          SELECT 1 FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind = 'c'
        ))
        AND NOT EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e'
        )
    LOOP
      EXECUTE format('DROP TYPE IF EXISTS %s CASCADE', obj.name);
    END LOOP;
  END
  $kiln_demo_wipe$;
  """

  @doc "Table names whose rows a restore never carries over."
  @spec excluded_data() :: [String.t()]
  def excluded_data, do: @excluded_data

  @doc """
  Reads a golden archive's table of contents. Refuses a missing or unreadable
  file before anything destructive has happened.
  """
  @spec read_golden(Path.t()) ::
          {:ok, golden()}
          | {:error, {:golden_missing, Path.t()} | {:golden_unreadable, String.t()}}
  def read_golden(path) do
    if File.regular?(path) do
      case cmd("pg_restore", ["--list", path]) do
        {:ok, listing} ->
          {:ok, %{path: path, source_database: source_database(listing), listing: listing}}

        {:error, reason} ->
          {:error, {:golden_unreadable, describe(reason)}}
      end
    else
      {:error, {:golden_missing, path}}
    end
  end

  @doc """
  The database an archive was dumped from, from its `--list` header, or `nil`.
  """
  @spec source_database(String.t()) :: String.t() | nil
  def source_database(listing) do
    case Regex.run(~r/^;\s+dbname:\s*(\S+)\s*$/m, listing) do
      [_, name] -> name
      _ -> nil
    end
  end

  @doc """
  The restore list: `listing` with the entries a demo restore must skip turned
  into comments (`pg_restore --use-list` ignores lines starting with `;`).

  Skipped: extensions and their comments (see the moduledoc), the `public`
  schema itself (it exists, and the wipe kept it), and the rows of
  `excluded_data/0`.
  """
  @spec filter_listing(String.t()) :: String.t()
  def filter_listing(listing) do
    listing
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      if skip?(line), do: "; skipped by demo reset: " <> line, else: line
    end)
  end

  @entry ~r/^\d+;\s+\d+\s+\d+\s+(.*)$/

  defp skip?(line) do
    case Regex.run(@entry, line) do
      [_, rest] -> skip_entry?(rest)
      _ -> false
    end
  end

  defp skip_entry?("EXTENSION " <> _), do: true
  defp skip_entry?("COMMENT - EXTENSION " <> _), do: true
  defp skip_entry?("SCHEMA - public" <> rest), do: public_schema_entry?(rest)
  defp skip_entry?("COMMENT - SCHEMA public" <> rest), do: public_schema_entry?(rest)

  defp skip_entry?("TABLE DATA public " <> rest) do
    [table | _owner] = String.split(rest, " ", parts: 2)
    table in @excluded_data
  end

  defp skip_entry?(_rest), do: false

  # `SCHEMA - public_extra` is a different schema, not the public one.
  defp public_schema_entry?(""), do: true
  defp public_schema_entry?(" " <> _owner), do: true
  defp public_schema_entry?(_other), do: false

  @doc """
  Renders the golden archive into the two scripts `run/2` runs, under `dir`.

  Rendering needs no database connection, so an archive that `pg_restore`
  cannot turn into SQL is refused here, before any live state has been touched.
  Both files hold the demo's full contents, so they are written `0600` and
  removed by `cleanup/1`.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec prepare(golden(), Path.t()) :: {:ok, work()} | {:error, {:restore_failed, String.t()}}
  def prepare(%{path: path, listing: listing}, dir) do
    work = %{dir: dir, wipe: Path.join(dir, "wipe.sql"), restore: Path.join(dir, "restore.sql")}
    list = Path.join(dir, "restore.list")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(work.wipe, @wipe_sql),
         :ok <- File.write(list, filter_listing(listing)),
         {:ok, _} <-
           cmd("pg_restore", [
             "--no-owner",
             "--no-privileges",
             "--use-list=#{list}",
             "--file=#{work.restore}",
             path
           ]),
         :ok <- File.chmod(work.restore, 0o600) do
      File.rm(list)
      {:ok, work}
    else
      error ->
        cleanup(work)
        {:error, {:restore_failed, describe(error)}}
    end
  end

  @doc """
  Applies prepared scripts to the database at `url`, in one transaction.

  `ON_ERROR_STOP` makes the first failing statement abort the whole run, which
  under `--single-transaction` is a rollback of everything, wipe included.
  `--no-psqlrc` so an operator's `~/.psqlrc` can't change what runs.

  Query output goes to `/dev/null` and notices are suppressed, so what comes
  back on failure is the error alone — not a `set_config` result row and a
  "drop cascades to" notice per table ahead of the one line that matters.
  """
  @spec run(work(), String.t()) :: :ok | {:error, {:restore_failed, String.t()}}
  def run(%{wipe: wipe, restore: restore}, url) do
    {url, env} = Worker.split_credentials(url)
    env = [{"PGOPTIONS", "-c client_min_messages=warning"} | env]

    args = [
      "--no-psqlrc",
      "--quiet",
      "--output=/dev/null",
      "--set=ON_ERROR_STOP=1",
      "--single-transaction",
      "--file=#{wipe}",
      "--file=#{restore}",
      "--dbname=#{url}"
    ]

    case cmd("psql", args, env) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:restore_failed, describe(reason)}}
    end
  end

  @doc """
  Dumps the database at `url` to `path` in the format `read_golden/1` reads — the
  same flags as `KilnCMS.Backups`, `.partial` until it verifies.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec dump(String.t(), Path.t()) :: :ok | {:error, {:dump_failed, String.t()}}
  def dump(url, path) do
    {url, env} = Worker.split_credentials(url)
    partial = path <> ".partial"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, _} <-
           cmd(
             "pg_dump",
             ["--format=custom", "--no-owner", "--no-privileges", "--file=#{partial}", url],
             env
           ),
         {:ok, _} <- cmd("pg_restore", ["--list", partial]),
         :ok <- File.chmod(partial, 0o600),
         :ok <- File.rename(partial, path) do
      :ok
    else
      error ->
        File.rm(partial)
        {:error, {:dump_failed, describe(error)}}
    end
  end

  @doc "Removes the rendered scripts. Always `:ok`."
  # sobelow_skip ["Traversal.FileModule"]
  @spec cleanup(work()) :: :ok
  def cleanup(%{dir: dir}) do
    File.rm_rf(dir)
    :ok
  end

  # argv, never a shell — the URL carries a host and a database name, and its
  # password travels as PGPASSWORD (`Worker.split_credentials/1`) rather than
  # sitting in world-readable argv for the length of a restore.
  # sobelow_skip ["CI.System"]
  defp cmd(executable, args, env \\ []) do
    case System.cmd(executable, args, env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:exit_status, executable, status, redact(output, env)}}
    end
  rescue
    error -> {:error, {executable, Exception.message(error)}}
  end

  # These messages reach the job's cancel reason and the operator's console, and
  # `psql`/`pg_dump` echo connection details on failure. Same two passes as
  # `KilnCMS.Backups.Worker`: the known secret literally, then any URL userinfo.
  defp redact(output, env) do
    env
    |> Enum.reduce(output, fn {_var, secret}, acc ->
      if String.length(secret) >= 6, do: String.replace(acc, secret, "***"), else: acc
    end)
    |> String.replace(~r{([a-z][a-z0-9+.-]*://)[^@\s/]+@}i, "\\1***@")
    |> String.slice(0, 500)
  end

  defp describe({:error, {:exit_status, executable, status, output}}),
    do: "#{executable} exited #{status}: #{String.trim(output)}"

  defp describe({:exit_status, executable, status, output}),
    do: "#{executable} exited #{status}: #{String.trim(output)}"

  defp describe({:error, {executable, message}}) when is_binary(message),
    do: "#{executable}: #{message}"

  defp describe({:error, reason}), do: inspect(reason)
  defp describe(reason), do: inspect(reason)
end
