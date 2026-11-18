defmodule KilnCMS.Backups.Preflight do
  @moduledoc """
  The free-space check a backup makes before it writes a component (#2423).

  A backup that runs the disk full fails late, after minutes of `pg_dump` or
  `tar`, and leaves the host short of space for everything else on it. So the
  step that starts a component first compares the free space where it will
  write with an estimate of what it needs, and refuses at once when there is
  too little. The refusal is fatal (no retries: a retry a minute later finds
  the same disk) and says how much is free, how much is needed and what to do.

  The dump step checks `<BACKUP_DIR>/db` before `pg_dump` starts; the plan
  step checks `<BACKUP_DIR>/media` once the plan is known, before the first
  part is archived. Each checks the directory it writes to (its nearest
  existing ancestor), so a `db/` or `media/` mounted from another disk is
  measured on that disk. A run with both components is checked twice, the
  media check after the dump has landed.

  ## The estimate

  What a step needs is its estimate plus 10% plus a fixed margin
  (`config :kiln_cms, KilnCMS.Backups, free_space_margin_bytes:`, default
  256 MB), as `needed/1` computes:

    * **The dump**: the size of the newest earlier dump in `<BACKUP_DIR>/db`
      (`dump_estimate/2`), not `pg_database_size()`. A custom-format dump is
      compressed and leaves out index contents, so it is commonly a fraction
      of the database's size on disk; checking against that size would refuse
      backups that fit. The newest dump is what the next one will be, give or
      take a day's growth, which the 10% covers. With no earlier dump (a
      first backup) the estimate is 0 and only the margin is checked.
    * **The media**: the input bytes of the plan's parts not already
      archived (a resume keeps those). Media files are mostly compressed
      already, so a part's `tar.gz` is close to its input size.

  `scripts/backup.sh` checks the same estimates with the same arithmetic and
  default margin.

  ## When free space can't be read

  Free space is read with `df -Pk` (POSIX output, the same columns on GNU and
  BSD `df`), bounded to 10 seconds. If `df` is missing, fails, times out or
  prints something unparseable, the check **fails open**: it logs a warning,
  returns `:unknown` and the backup goes ahead. Refusing on an unknown would
  stop every backup on a host whose `df` can't be read, and a disk that does
  fill up is still a step failure (`ENOSPC`), only a later one.

  `config :kiln_cms, KilnCMS.Backups, free_space:` swaps the reading for a
  function from a path to `{:ok, bytes}` or `:error`, in tests only.
  """
  alias KilnCMS.{AVProcessor, ExternalCommand}

  require Logger

  @default_margin_bytes 256 * 1_048_576
  @df_timeout_ms 10_000

  @typedoc "Which component a check is for."
  @type component :: :db | :media

  @typedoc "A refusal: what was measured where, and what was needed."
  @type shortfall ::
          {:insufficient_space,
           %{
             component: component(),
             path: Path.t(),
             free: non_neg_integer(),
             needed: non_neg_integer()
           }}

  @doc """
  Check that the file system holding `path` has room for `estimate` bytes of
  `component`, plus the margin (`needed/1`).

  `:ok` when it has, `{:error, shortfall}` when it hasn't, and `:unknown`
  (after a logged warning) when free space can't be read: the caller goes
  ahead.
  """
  @spec check(component(), Path.t(), non_neg_integer()) :: :ok | :unknown | {:error, shortfall()}
  def check(component, path, estimate)
      when component in [:db, :media] and is_integer(estimate) and estimate >= 0 do
    needed = needed(estimate)
    measured = existing(path)

    case free_bytes(measured) do
      {:ok, free} when free >= needed ->
        :ok

      {:ok, free} ->
        {:error,
         {:insufficient_space,
          %{component: component, path: measured, free: free, needed: needed}}}

      :error ->
        Logger.warning(
          "Backup free-space check skipped: could not read the free space in #{measured}"
        )

        :unknown
    end
  end

  @doc """
  What a component estimated at `estimate` bytes needs: the estimate plus 10%
  plus `margin_bytes/0`.
  """
  @spec needed(non_neg_integer()) :: non_neg_integer()
  def needed(estimate) when is_integer(estimate) and estimate >= 0,
    do: div(estimate * 11, 10) + margin_bytes()

  @doc """
  The fixed margin added to every estimate, in bytes
  (`free_space_margin_bytes`, default 256 MB).
  """
  @spec margin_bytes() :: non_neg_integer()
  def margin_bytes do
    case config(:free_space_margin_bytes, @default_margin_bytes) do
      bytes when is_integer(bytes) and bytes >= 0 -> bytes
      _invalid -> @default_margin_bytes
    end
  end

  @doc """
  The dump estimate: the size of the newest regular `kiln-db-<stamp>.dump`
  file in `db_dir` other than `stamp`'s own (stamps sort by time), or 0 when
  there is none.
  """
  # `db_dir` is `<BACKUP_DIR>/db`; only names matching the dump pattern are
  # stat'ed, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  @spec dump_estimate(Path.t(), String.t()) :: non_neg_integer()
  def dump_estimate(db_dir, stamp) when is_binary(stamp) do
    own = "kiln-db-#{stamp}.dump"

    case File.ls(db_dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&(dump_name?(&1) and &1 != own))
        |> Enum.sort(:desc)
        |> Enum.find_value(0, &regular_size(Path.join(db_dir, &1)))

      {:error, _} ->
        0
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp regular_size(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} -> size
      _other -> nil
    end
  end

  defp dump_name?(name),
    do: String.starts_with?(name, "kiln-db-") and String.ends_with?(name, ".dump")

  @doc """
  The message for a refusal: where, how much is free, how much is needed, and
  the two ways out. `scripts/backup.sh` prints the same words.
  """
  @spec describe(shortfall()) :: String.t()
  def describe(
        {:insufficient_space, %{component: component, path: path, free: free, needed: needed}}
      ) do
    "Not enough free space for the #{what(component)} in #{path}: #{human(free)} free, " <>
      "about #{human(needed)} needed. Free up space there, or point BACKUP_DIR at a larger disk"
  end

  defp what(:db), do: "database dump"
  defp what(:media), do: "media archive"

  @doc """
  `bytes` in the units the refusal uses: whole MB below 1 GB, GB with one
  decimal from there (1 MB = 1,048,576 bytes).
  """
  @spec human(non_neg_integer()) :: String.t()
  def human(bytes) when bytes < 1_073_741_824, do: "#{div(bytes, 1_048_576)} MB"

  def human(bytes) do
    tenths = div(bytes * 10, 1_073_741_824)
    "#{div(tenths, 10)}.#{rem(tenths, 10)} GB"
  end

  # The nearest directory that exists: `df` refuses a path that doesn't, and
  # `db/` or `media/` is created by the step that writes into it.
  defp existing(path) do
    parent = Path.dirname(path)

    cond do
      File.dir?(path) -> path
      parent == path -> path
      true -> existing(parent)
    end
  end

  defp free_bytes(path) do
    case config(:free_space, nil) do
      fun when is_function(fun, 1) -> fun.(path)
      nil -> df(path)
    end
  end

  # `path` is the backup directory or one under it, never request input, and
  # `ExternalCommand` execs `df` directly, with no shell. `AVProcessor`
  # already parses `df -Pk` for its temp-space check; this reads it the same
  # way.
  defp df(path) do
    with exe when is_binary(exe) <- System.find_executable("df"),
         {output, 0} <- ExternalCommand.run(exe, ["-Pk", path], @df_timeout_ms) do
      AVProcessor.parse_available(output)
    else
      _no_reading -> :error
    end
  end

  defp config(key, default),
    do: :kiln_cms |> Application.get_env(KilnCMS.Backups, []) |> Keyword.get(key, default)
end
