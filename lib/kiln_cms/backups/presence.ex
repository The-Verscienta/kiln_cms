defmodule KilnCMS.Backups.Presence do
  @moduledoc """
  Whether a recorded backup's files are still on this host's disk (#2217).

  A `KilnCMS.Backups.Run` is history: it stays true after retention, an
  operator's `rm` or a restore onto a different host. Presence is therefore
  **computed on read** (never stored) by `File.stat/1` on the run's artifacts,
  for the runs on the page being shown, so the cost is bounded by the page size.

    * `:present` - every artifact file is a regular file under `dir`.
    * `:pruned` - the application's own retention removed them (the artifact's
      `"local"` destination is marked `"pruned"`).
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

  @type t :: :present | :pruned | :off_site_only | :expired | :missing | :none

  @doc """
  The presence of `run`'s files under `dir`.

  `keep_days` and `now` only matter for the `:expired` heuristic.
  """
  @spec for(Run.t(), Path.t(), pos_integer(), DateTime.t()) :: t()
  def for(run, dir, keep_days, now \\ DateTime.utc_now())

  def for(%Run{artifacts: []}, _dir, _keep_days, _now), do: :none

  def for(%Run{artifacts: artifacts} = run, dir, keep_days, now) when is_binary(dir) do
    states = Enum.map(artifacts, &{&1, local_state(&1, dir)})
    absent = for {artifact, state} <- states, state != :present, do: {artifact, state}

    cond do
      absent == [] -> :present
      length(absent) < length(states) -> :missing
      Enum.all?(absent, fn {_artifact, state} -> state == :pruned end) -> :pruned
      Enum.all?(absent, fn {artifact, _state} -> off_site?(artifact) end) -> :off_site_only
      expired?(run, keep_days, now) -> :expired
      true -> :missing
    end
  end

  defp local_state(%Artifact{} = artifact, dir) do
    path = Path.join([dir, Artifact.subdir(artifact.kind), Path.basename(artifact.name)])

    # `lstat`, like the importer: a symlink named like an artifact is not one.
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :present
      _ -> if pruned?(artifact), do: :pruned, else: :gone
    end
  end

  defp pruned?(%Artifact{destinations: %{"local" => %{"status" => "pruned"}}}), do: true
  defp pruned?(_artifact), do: false

  defp off_site?(%Artifact{destinations: destinations}) do
    Enum.any?(destinations, fn
      {"rclone:" <> _remote, %{"status" => "ok"}} -> true
      _ -> false
    end)
  end

  defp expired?(%Run{origin: :imported, started_at: %DateTime{} = started}, keep_days, now),
    do: DateTime.diff(now, started, :day) > keep_days + 1

  defp expired?(_run, _keep_days, _now), do: false
end
