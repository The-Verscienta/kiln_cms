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
  part is archived, and the work directory (`<BACKUP_DIR>/.work/<stamp>`),
  where each part's filtered copy of its file list is written. Each checks the
  directory it writes to (its nearest existing ancestor), so a `db/`,
  `media/` or `.work/` mounted from another disk is measured on that disk. A
  run with both components is checked twice, the media check after the dump
  has landed.

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
      archived (a resume keeps those). This is an **upper bound**: photos and
      video are compressed already, so their parts come out close to it, but
      TIFF, BMP, SVG, uncompressed audio and sparse files shrink in a
      `tar.gz`, and a file linked under two names is counted twice. A library
      of mostly such files can be refused when it would fit.
    * **The lists**: the largest of the plan's file lists, the size of the
      filtered copy written beside it while a part is archived.

  `scripts/backup.sh` checks the dump and the media with the same estimates,
  arithmetic and default margin. Its lists are in `TMPDIR`, often a small
  `tmpfs` where the margin alone could refuse a run that fits, so it does not
  check them.

  ## Turning it off

  `config :kiln_cms, KilnCMS.Backups, free_space_check: false`
  (`BACKUP_FREE_SPACE_CHECK=false`, which `scripts/backup.sh` reads too) skips
  every check: for a backup the estimate refuses although it fits, because
  the media compresses well or the disk is one `df` misreports. A disk that
  does fill up is then a step failure (`ENOSPC`), as before #2423.

  ## When free space can't be read

  Free space is read with `df -Pk` (POSIX output, bounded to 10 seconds).
  Available is the field two before the `NN%` capacity field, so a file
  system named with a space (`//host/Share Name`) reads right. If `df` is
  missing, fails, times out or prints something unparseable, the check
  **fails open**: it logs a warning, returns `:unknown` and the backup goes
  ahead. Refusing on an unknown would stop every backup on a host whose `df`
  can't be read, and a disk that does fill up is still a step failure
  (`ENOSPC`), only a later one.

  `config :kiln_cms, KilnCMS.Backups, free_space:` swaps the reading for a
  function from a path to `{:ok, bytes}` or `:error`, in tests only.
  """
  alias KilnCMS.Backups.Artifact
  alias KilnCMS.ExternalCommand

  require Logger

  @default_margin_bytes 256 * 1_048_576
  @df_timeout_ms 10_000
  @kb 1024
  @mb 1_048_576
  @gb 1_073_741_824

  @typedoc "What a check is for: the dump, the media parts, or their file lists."
  @type component :: :db | :media | :lists

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

  `:ok` when it has (or the check is off, `enabled?/0`), `{:error, shortfall}`
  when it hasn't, and `:unknown` (after a logged warning) when free space
  can't be read: the caller goes ahead.
  """
  @spec check(component(), Path.t(), non_neg_integer()) :: :ok | :unknown | {:error, shortfall()}
  def check(component, path, estimate)
      when component in [:db, :media, :lists] and is_integer(estimate) and estimate >= 0 do
    if enabled?(), do: measure(component, path, needed(estimate)), else: :ok
  end

  defp measure(component, path, needed) do
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
  Whether the check runs (`free_space_check`, `BACKUP_FREE_SPACE_CHECK`;
  default on). Only `false` turns it off.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: config(:free_space_check, true) != false

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
  The dump estimate: the size of the regular file
  `kiln-db-<YYYYMMDD-HHMMSS>.dump` in `db_dir` with the newest stamp earlier
  than `stamp` (this run's), or 0 when there is none. A name without a stamp
  (an operator's `kiln-db-manual.dump`) and one stamped later than this run
  are not backups this estimate can follow, and are passed over.
  """
  # `db_dir` is `<BACKUP_DIR>/db`; only names matching the dump pattern are
  # stat'ed, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  @spec dump_estimate(Path.t(), String.t()) :: non_neg_integer()
  def dump_estimate(db_dir, stamp) when is_binary(stamp) do
    case File.ls(db_dir) do
      {:ok, names} ->
        names
        |> Enum.flat_map(&earlier_dump(&1, stamp))
        |> Enum.sort(:desc)
        |> Enum.find_value(0, fn {_stamp, name} -> regular_size(Path.join(db_dir, name)) end)

      {:error, _} ->
        0
    end
  end

  defp earlier_dump(name, own) do
    with {:ok, stamp} <- Artifact.name_stamp(name),
         true <- name == "kiln-db-#{stamp}.dump" and stamp < own do
      [{stamp, name}]
    else
      _other -> []
    end
  end

  @doc """
  The lists estimate: the size of the largest of `lists` (paths), what one
  part's filtered copy of its list can take. Missing files count as 0.
  """
  # Generated list names in the work directory (`MediaArchive.plan/3`).
  # sobelow_skip ["Traversal.FileModule"]
  @spec lists_estimate([Path.t()]) :: non_neg_integer()
  def lists_estimate(lists) when is_list(lists) do
    lists
    |> Enum.map(&(regular_size(&1) || 0))
    |> Enum.max(fn -> 0 end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp regular_size(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} -> size
      _other -> nil
    end
  end

  @doc """
  The message for a refusal: where, how much is free, how much is needed, and
  the ways out. `scripts/backup.sh` prints the same words.
  """
  @spec describe(shortfall()) :: String.t()
  def describe(
        {:insufficient_space, %{component: component, path: path, free: free, needed: needed}}
      ) do
    "Not enough free space for the #{what(component)} in #{path}: #{human(free, :down)} free, " <>
      "about #{human(needed, :up)} needed. Free up space there, or point BACKUP_DIR at a " <>
      "larger disk (BACKUP_FREE_SPACE_CHECK=false skips this check)"
  end

  defp what(:db), do: "database dump"
  defp what(:media), do: "media archive"
  defp what(:lists), do: "media file lists"

  @doc """
  `bytes` in the units a refusal uses: KB below 1 MB, whole MB below 1 GB, GB
  to one decimal from there (1 KB = 1024 bytes), rounded `:down` (what is
  free) or `:up` (what is needed), so a refusal never reads as if the two
  were equal.
  """
  @spec human(non_neg_integer(), :down | :up) :: String.t()
  def human(bytes, round) when bytes < @mb, do: "#{divide(bytes, @kb, round)} KB"
  def human(bytes, round) when bytes < @gb, do: "#{divide(bytes, @mb, round)} MB"

  def human(bytes, round) do
    tenths = divide(bytes * 10, @gb, round)
    "#{div(tenths, 10)}.#{rem(tenths, 10)} GB"
  end

  defp divide(n, by, :down), do: div(n, by)
  defp divide(n, by, :up), do: div(n + by - 1, by)

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
  # `ExternalCommand` execs `df` directly, with no shell.
  defp df(path) do
    with exe when is_binary(exe) <- System.find_executable("df"),
         {output, 0} <- ExternalCommand.run(exe, ["-Pk", path], @df_timeout_ms) do
      parse_df(output)
    else
      _no_reading -> :error
    end
  end

  @doc """
  The available bytes in `df -Pk` output: on the first line after the header,
  the field two before the first `NN%` field that follows three whole
  numbers (total, used, available; a negative available reads as 0). A positional read of the 4th field
  (`AVProcessor.parse_available/1`) misreads a file system whose name has a
  space in it; this one doesn't. `:error` for anything else.
  """
  @spec parse_df(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse_df(output) when is_binary(output) do
    case String.split(output, "\n", trim: true) do
      [_header, line | _rest] -> line |> String.split() |> available_field()
      _other -> :error
    end
  end

  defp available_field([total, used, available, capacity | rest]) do
    if capacity =~ ~r/\A\d+%\z/ and total =~ ~r/\A\d+\z/ and used =~ ~r/\A\d+\z/ and
         available =~ ~r/\A-?\d+\z/,
       # A negative Available (BSD's reserve, overdrawn) is none.
       do: {:ok, max(String.to_integer(available), 0) * @kb},
       else: available_field([used, available, capacity | rest])
  end

  defp available_field(_fields), do: :error

  defp config(key, default),
    do: :kiln_cms |> Application.get_env(KilnCMS.Backups, []) |> Keyword.get(key, default)
end
