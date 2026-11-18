defmodule KilnCMS.Backups.Presence do
  @moduledoc """
  Whether a recorded backup's files are still on this host's disk, artifact by
  artifact (#2217, #2416).

  A `KilnCMS.Backups.Run` is history: it stays true after retention, an
  operator's `rm` or a restore onto a different host. Presence is therefore
  **computed on read** (never stored), for the runs on the page being shown, so
  the cost is bounded by the page size. `context/2` lists `db/` and `media/`
  once; a file is `lstat`ed only when its name is in that listing.

  ## One state per file, per artifact, per run

  Each file an artifact occupies (the dump, the single archive, or each part
  of a media set; never the checksum sidecar) is one **unit**:

    * `:present` - a regular file under the directory (`lstat`, so a symlink
      or a directory named like it is not it).
    * `:unknown` - the directory couldn't be listed, or the file couldn't be
      `lstat`ed for a reason other than its absence (`:eacces`, `:eio`,
      `:estale`, ...). Nothing is claimed about it.
    * otherwise the unit is absent, and the first reason that applies names it:
      * `:pruned` - the application's own retention removed it (its `"local"`
        destination is marked `"pruned"`).
      * `:off_site_only` - a copy of it reached an off-site destination
        (any key but `"local"` recorded `"ok"`: the rclone remote or a stored
        destination, #2220).
      * `:expired` / `:probably_expired` - see below.
      * `:missing` - gone for no recorded reason (deleted out of band, or the
        run was recorded on another node: `BACKUP_DIR` is host-local).

  An **artifact** is `:present` when every unit is, `:unknown` when any unit
  is, `:partly_pruned` when some units are here and every absent one was
  pruned, and `:missing` (with the absent files in `gone`) when some are here
  and others are gone for another reason. The files of `gone` that reached an
  off-site destination are also in `off_site` (#2942), so the row can say
  which of them have a copy there. When none is here, the worst reason among
  its units wins: `:missing`, then `:probably_expired`, `:expired`,
  `:pruned`, `:off_site_only`.

  A **run** is the state its artifacts share, `:mixed` when they differ (read
  `artifacts` then), and `:none` when it produced no artifacts.

  ## Expired: what cron's prune removed

  The app's own retention records what it deletes (`:pruned`); cron's
  `scripts/backup.sh prune` records nothing, so for a cron-made (imported) run
  an absent unit is judged by cron's rule, as far as this side can see it:

    * a recovery point (`kiln-<stamp>.keep`), or a `.good` or `.hold` marker
      in the unit's own directory, means prune keeps it, so it is `:missing`;
    * prune never deletes the newest complete unit of a kind, so without a
      newer complete unit of the same kind in the listing it is `:missing`;
    * otherwise its age (`finished_at`, else `started_at`) against cron's
      `BACKUP_KEEP_DAYS`, which `backup.sh` writes into `manifest.json`
      (`cron_keep_days`): older than that plus a day is `:expired`, younger is
      `:missing`. When no manifest of cron's says, the app's `keep_days`
      stands in, and an older unit is only `:probably_expired`.

  When a marker directory couldn't be listed, a marker can't be ruled out, so
  no unit is called expired. An app-made run is never expired: its prunes are
  recorded. Cron pruning the app's files in a shared `BACKUP_DIR` therefore
  reads `:missing`.
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Markers, Retention, Run}

  @type unit_state ::
          :present
          | :pruned
          | :partly_pruned
          | :off_site_only
          | :expired
          | :probably_expired
          | :missing
          | :unknown

  @type artifact_presence :: %{
          kind: :db | :media,
          name: String.t(),
          state: unit_state(),
          gone: [String.t()],
          off_site: [String.t()],
          parts: pos_integer() | nil
        }

  @type t :: %{state: unit_state() | :mixed | :none, artifacts: [artifact_presence()]}

  defmodule Context do
    @moduledoc """
    What `KilnCMS.Backups.Presence.for/2` judges against: one listing of the
    backup directory's `db/` and `media/`, the markers in it, and the clock and
    retention windows. Built once per page by
    `KilnCMS.Backups.Presence.context/2`.
    """
    @type listing :: {:ok, MapSet.t(String.t())} | {:error, term()}

    @type t :: %__MODULE__{
            dir: Path.t(),
            listing: %{db: listing(), media: listing()},
            markers: KilnCMS.Backups.Markers.t(),
            newest_complete: %{db: String.t() | nil, media: String.t() | nil},
            now: DateTime.t(),
            cron_keep_days: pos_integer() | nil,
            app_keep_days: pos_integer()
          }

    @enforce_keys [:dir, :listing, :markers, :newest_complete, :now, :app_keep_days]
    defstruct [
      :dir,
      :listing,
      :markers,
      :newest_complete,
      :now,
      :app_keep_days,
      cron_keep_days: nil
    ]
  end

  @kinds [:db, :media]

  # Worst first: the state an artifact with no unit left reads as.
  @absent_order [:missing, :probably_expired, :expired, :pruned, :off_site_only]

  @doc """
  List `dir`'s `db/` and `media/` once and build the context `for/2` judges
  against.

  Options: `:now` (default `DateTime.utc_now/0`), `:cron_keep_days` (cron's
  `BACKUP_KEEP_DAYS` as its manifest recorded it, default `nil`: unknown) and
  `:app_keep_days` (default `KilnCMS.Backups.keep_days/0`).
  """
  @spec context(Path.t(), keyword()) :: Context.t()
  def context(dir, opts \\ []) when is_binary(dir) do
    raw = Map.new(@kinds, &{&1, Markers.list(dir, &1)})
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    listing =
      Map.new(raw, fn
        {kind, {:ok, names}} -> {kind, {:ok, MapSet.new(names)}}
        {kind, {:error, reason}} -> {kind, {:error, reason}}
      end)

    %Context{
      dir: dir,
      listing: listing,
      markers: Markers.from_listing(raw),
      newest_complete: Map.new(@kinds, &{&1, newest_complete(&1, listing[&1], now)}),
      now: now,
      cron_keep_days: Keyword.get(opts, :cron_keep_days),
      app_keep_days: Keyword.get_lazy(opts, :app_keep_days, &Backups.keep_days/0)
    }
  end

  @doc "The presence of `run`'s files, judged against `context` (see the moduledoc)."
  @spec for(Run.t(), Context.t()) :: t()
  def for(%Run{artifacts: []}, %Context{}), do: %{state: :none, artifacts: []}

  def for(%Run{artifacts: artifacts} = run, %Context{} = context) do
    expirable? = expirable?(run, context)
    judged = Enum.map(artifacts, &artifact(&1, run, context, expirable?))

    state =
      case judged |> Enum.map(& &1.state) |> Enum.uniq() do
        [one] -> one
        _several -> :mixed
      end

    %{state: state, artifacts: judged}
  end

  defp artifact(%Artifact{} = artifact, run, context, expirable?) do
    states =
      for unit <- units(artifact), do: {unit, unit_state(unit, run, context, expirable?)}

    {here, absent} = Enum.split_with(states, fn {_unit, state} -> state == :present end)
    {state, gone} = verdict(here != [], absent)

    %{
      kind: artifact.kind,
      name: artifact.name,
      state: state,
      gone: gone,
      off_site: for({unit, :off_site_only} <- absent, unit.file in gone, do: unit.file),
      parts: if(artifact.parts == [], do: nil, else: length(artifact.parts))
    }
  end

  # `{state, gone}` for an artifact, from whether any unit is here and the
  # `{unit, state}` of the absent ones.
  defp verdict(_any_here?, []), do: {:present, []}

  defp verdict(any_here?, absent) do
    states = Enum.map(absent, &elem(&1, 1))

    cond do
      :unknown in states -> {:unknown, []}
      any_here? and Enum.all?(states, &(&1 == :pruned)) -> {:partly_pruned, []}
      any_here? -> {:missing, for({unit, state} <- absent, state != :pruned, do: unit.file)}
      true -> {worst(states), []}
    end
  end

  defp worst(states), do: Enum.find(@absent_order, :missing, &(&1 in states))

  # `%{kind, file, local, destinations}`: one per file the artifact occupies. A
  # part's own recorded destinations win; one with none recorded (a set
  # imported from disk) falls back to the artifact's.
  defp units(%Artifact{parts: [_ | _] = parts} = artifact) do
    for %{} = part <- parts, is_binary(part["name"]) do
      %{
        kind: artifact.kind,
        file: Path.basename(part["name"]),
        local: local_of(part["destinations"], artifact.destinations),
        destinations: part["destinations"] || artifact.destinations
      }
    end
  end

  defp units(%Artifact{} = artifact) do
    [
      %{
        kind: artifact.kind,
        file: Path.basename(artifact.name),
        local: local_of(artifact.destinations, %{}),
        destinations: artifact.destinations
      }
    ]
  end

  defp local_of(%{"local" => %{"status" => status}}, _fallback), do: status
  defp local_of(_own, %{"local" => %{"status" => status}}), do: status
  defp local_of(_own, _fallback), do: nil

  defp unit_state(unit, run, context, expirable?) do
    case on_disk(unit, context) do
      :present -> :present
      :unknown -> :unknown
      :absent -> absent_reason(unit, run, context, expirable?)
    end
  end

  # Only a listed name is `lstat`ed: an unlisted one is absent without a
  # syscall, and a listing that failed claims nothing.
  defp on_disk(unit, context) do
    case Map.get(context.listing, unit.kind) do
      {:ok, names} ->
        if MapSet.member?(names, unit.file),
          do: lstat(Path.join([context.dir, Artifact.subdir(unit.kind), unit.file])),
          else: :absent

      _unlistable ->
        :unknown
    end
  end

  # `lstat`, like the importer: a symlink named like an artifact is not one.
  # Only "no such file" is absence; any other error claims nothing.
  # sobelow_skip ["Traversal.FileModule"]
  defp lstat(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :present
      {:ok, %File.Stat{}} -> :absent
      {:error, :enoent} -> :absent
      {:error, _cannot_tell} -> :unknown
    end
  end

  defp absent_reason(unit, run, context, expirable?) do
    cond do
      unit.local == "pruned" -> :pruned
      off_site?(unit) -> :off_site_only
      expirable? and not pinned?(unit, run, context) -> expiry(unit, run, context)
      true -> :missing
    end
  end

  defp off_site?(%{destinations: destinations}) when is_map(destinations) do
    Enum.any?(destinations, fn
      {"local", _local} -> false
      {key, %{"status" => "ok"}} when is_binary(key) -> true
      _ -> false
    end)
  end

  defp off_site?(_unit), do: false

  # Cron's prune is the only remover of an imported run's files that leaves
  # no record, and it can only be judged when every marker directory was read.
  defp expirable?(%Run{origin: :imported, stamp: stamp}, context) when is_binary(stamp),
    do: Markers.unreadable(context.markers) == []

  defp expirable?(_run, _context), do: false

  defp pinned?(unit, run, context) do
    Markers.recovery_point?(context.markers, run.stamp) or
      unit.kind in Markers.last_good_components(context.markers, run.stamp) or
      unit.kind in Markers.held_components(context.markers, run.stamp)
  end

  defp expiry(unit, run, context) do
    newest = Map.get(context.newest_complete, unit.kind)
    at = run.finished_at || run.started_at

    cond do
      # Prune never deletes the newest complete unit of a kind.
      not (is_binary(newest) and newest > run.stamp) -> :missing
      not match?(%DateTime{}, at) -> :missing
      is_integer(context.cron_keep_days) -> aged(at, context.cron_keep_days, :expired, context)
      true -> aged(at, context.app_keep_days, :probably_expired, context)
    end
  end

  defp aged(at, keep_days, state, context) do
    if DateTime.diff(context.now, at, :second) > (keep_days + 1) * 86_400,
      do: state,
      else: :missing
  end

  # The newest stamp whose unit of `kind` is complete by its listed names, as
  # `scripts/backup.sh` (`newest_complete_stamp`) and
  # `KilnCMS.Backups.Retention.complete?/1` judge it, from names alone: a dump;
  # or a single media archive and no parts; or parts 01..N with no gap, no
  # single archive and the media sidecar. A stamp with a `.partial` is in
  # flight and doesn't count, nor does an implausible one.
  defp newest_complete(_kind, {:error, _reason}, _now), do: nil

  defp newest_complete(kind, {:ok, names}, now) do
    unix = DateTime.to_unix(now)

    names
    |> Enum.flat_map(&member(&1, kind))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {stamp, members} ->
      Retention.plausible_stamp?(stamp, unix) and complete?(kind, members)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.max(fn -> nil end)
  end

  defp member(name, kind) do
    case Artifact.parse_file(name) do
      {:ok, %{kind: ^kind, stamp: stamp, part: part, partial?: partial?}} ->
        [{stamp, if(partial?, do: :partial, else: {:data, part})}]

      _not_data ->
        case Artifact.parse_sidecar_name(name) do
          {:ok, %{kind: ^kind, stamp: stamp, partial?: false}} -> [{stamp, :sidecar}]
          {:ok, %{kind: ^kind, stamp: stamp, partial?: true}} -> [{stamp, :partial}]
          _other -> []
        end
    end
  end

  defp complete?(kind, members) do
    if :partial in members do
      false
    else
      parts = for {:data, n} <- members, is_integer(n), do: n
      single? = {:data, nil} in members
      complete_files?(kind, single?, Enum.sort(parts), :sidecar in members)
    end
  end

  defp complete_files?(:db, single?, _parts, _sidecar?), do: single?
  defp complete_files?(:media, true, [], _sidecar?), do: true

  defp complete_files?(:media, false, [_ | _] = parts, true),
    do: parts == Enum.to_list(1..length(parts))

  defp complete_files?(:media, _single?, _parts, _sidecar?), do: false
end
