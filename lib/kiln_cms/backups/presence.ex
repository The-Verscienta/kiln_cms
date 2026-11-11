defmodule KilnCMS.Backups.Presence do
  @moduledoc """
  Whether a recorded backup's files are still on this host's disk (#2217).

  A `KilnCMS.Backups.Run` is history: it stays true after retention, an
  operator's `rm` or a restore onto a different host. Presence is therefore
  **computed on read** (never stored) by `File.stat/1` on the run's artifacts,
  for the runs on the page being shown, so the cost is bounded by the page size.

    * `:present` - every artifact file (every part of a media set) is a regular
      file under `dir`.
    * `:pruned` - the application's own retention removed them (the artifact's
      `"local"` destination is marked `"pruned"`).
    * `:partly_pruned` - some files are still here and every missing one was
      removed by the application's own retention. Retention ages a stamp's
      database dump and its media separately (#2219), so an old dump can go
      while the same backup's newer media stays.
    * `:off_site_only` - nothing is left locally, but every missing artifact has
      a successful rclone copy.
    * `:expired` - a cron-made (imported) run older than the retention window
      plus a day, so `backup.sh`'s own prune almost certainly removed it. A
      heuristic: cron records no prune.
    * `:missing` - files are gone for no recorded reason (deleted out-of-band, or
      the run was recorded on another node: `BACKUP_DIR` is host-local).
    * `:none` - the run produced no artifacts (a failed or skipped attempt).
  """
  alias KilnCMS.Backups.{Artifact, Run}

  @type t :: :present | :pruned | :partly_pruned | :off_site_only | :expired | :missing | :none

  @doc """
  The presence of `run`'s files under `dir`.

  `keep_days` and `now` only matter for the `:expired` heuristic.
  """
  @spec for(Run.t(), Path.t(), pos_integer(), DateTime.t()) :: t()
  def for(run, dir, keep_days, now \\ DateTime.utc_now())

  def for(%Run{artifacts: []}, _dir, _keep_days, _now), do: :none

  def for(%Run{artifacts: artifacts} = run, dir, keep_days, now) when is_binary(dir) do
    # One unit per FILE: a media set's parts are judged one by one, so a single
    # missing part makes the run `:missing` rather than `:present`. The checksum
    # sidecar is not an artifact and is never looked at.
    states =
      for artifact <- artifacts, unit <- units(artifact), do: {unit, local_state(unit, dir)}

    absent = for {unit, state} <- states, state != :present, do: {unit, state}

    cond do
      absent == [] -> :present
      length(absent) < length(states) -> some_absent(absent)
      true -> all_absent(absent, expired?(run, keep_days, now))
    end
  end

  defp some_absent(absent) do
    if Enum.all?(absent, fn {_unit, state} -> state == :pruned end),
      do: :partly_pruned,
      else: :missing
  end

  defp all_absent(absent, expired?) do
    cond do
      Enum.all?(absent, fn {_unit, state} -> state == :pruned end) -> :pruned
      Enum.all?(absent, fn {unit, _state} -> off_site?(unit) end) -> :off_site_only
      expired? -> :expired
      true -> :missing
    end
  end

  # `%{kind, file, local, destinations}`: one per file the artifact occupies. A
  # part's own recorded destinations win; one with none recorded (a set
  # imported from disk) falls back to the artifact's.
  defp units(%Artifact{parts: [_ | _] = parts} = artifact) do
    for %{} = part <- parts, is_binary(part["name"]) do
      %{
        kind: artifact.kind,
        file: part["name"],
        local: local_of(part["destinations"], artifact.destinations),
        destinations: part["destinations"] || artifact.destinations
      }
    end
  end

  defp units(%Artifact{} = artifact) do
    [
      %{
        kind: artifact.kind,
        file: artifact.name,
        local: local_of(artifact.destinations, %{}),
        destinations: artifact.destinations
      }
    ]
  end

  defp local_of(%{"local" => %{"status" => status}}, _fallback), do: status
  defp local_of(_own, %{"local" => %{"status" => status}}), do: status
  defp local_of(_own, _fallback), do: nil

  defp local_state(unit, dir) do
    path = Path.join([dir, Artifact.subdir(unit.kind), Path.basename(unit.file)])

    # `lstat`, like the importer: a symlink named like an artifact is not one.
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :present
      _ -> if unit.local == "pruned", do: :pruned, else: :gone
    end
  end

  defp off_site?(%{destinations: destinations}) do
    Enum.any?(destinations, fn
      {"rclone:" <> _remote, %{"status" => "ok"}} -> true
      _ -> false
    end)
  end

  defp expired?(%Run{origin: :imported, started_at: %DateTime{} = started}, keep_days, now),
    do: DateTime.diff(now, started, :day) > keep_days + 1

  defp expired?(_run, _keep_days, _now), do: false
end
