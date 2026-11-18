defmodule KilnCMS.Backups.Resend do
  @moduledoc """
  Re-sending a partly off-site backup to the destinations it missed (#2949):
  which runs may be re-sent, to where, and with which files.

  A backup that reached some destinations but not others succeeds **partly
  off-site** (`offsite_status: :partial`), and one whose stored destinations
  couldn't be read and that had no `BACKUP_RCLONE_REMOTE` succeeds **not
  off-site** (`:failed`, #2951). A re-send copies that run's verified files,
  as they are in `BACKUP_DIR`, to the destinations whose entry on the run is
  `failed` or `pending`, and re-derives the run's `offsite_status` from what
  it then reached. **It never changes the run's status**, never rebuilds a
  file and never writes a failure manifest.

  It runs as a short step chain under the backup lock
  (`KilnCMS.Backups.Chain.request_resend/1`): one `resend` step job per target
  destination, part k for the k-th, on the node with the run's backup
  directory, fenced by the lock like every backup step. While it holds the
  lock, a backup request queues behind it and another re-send is refused
  (owner decision O2). The steps are `KilnCMS.Backups.Steps`' "resend"
  section.

  ## Which runs (`eligible/2`)

  An in-app run that succeeded, whose off-site outcome is partial or failed
  (`KilnCMS.Backups.run_offsite_state/1`), with a backup directory id (#2539),
  every artifact verified with a recorded sha256, and none of its local files
  marked pruned by retention. Not within `Heartbeat.settled_after_ms/0` of
  its last re-send's Cancel, read from the run's log (the newest
  `"Re-send canceled"` entry's `at`): a step on a node that lost the
  database may still be stopping. And only while `BACKUP_ENABLED` is on
  (O11); a re-send runs neither `pg_dump` nor `pg_restore`, so nothing else
  of `KilnCMS.Backups.availability/0` applies.

  ## Which destinations (`targets/2`)

  Every entry of the run that is `failed` or `pending`, in the run's order,
  matched by key against the destinations configured now
  (`KilnCMS.Backups.Destination.configured/0`):

    * configured (the env remote with the same key, a stored destination
      still enabled): a target;
    * removed, disabled, or an env remote that changed: skipped, with a log
      line on the run; its entry stays failed (O5);
    * the `"unreadable"` entry (`KilnCMS.Backups.RunDestination.unreadable_key/0`):
      expanded into the enabled stored destinations the run has no entry for
      (O3), which replace it on the run once the re-send begins.

  ## Which files (`outputs/1`)

  The run's own artifacts, one entry per file and per media part
  (`KilnCMS.Backups.Artifact.output_entries/1`), with their checksum
  sidecars. Each is re-hashed immediately before each copy (ADR 0043), as a
  backup's off-site step does. A file that changed is **refused**: the
  re-send stops, the destination is recorded failed, the artifact is marked
  unverified on the run and in `manifest.json` when that is still this run's
  (O4, ADR 0071), and the file stays where it is. A file that is gone stops
  the re-send as "local files missing", not as a refusal.
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Heartbeat, Run, RunDestination, WorkState}

  @canceled_note "Re-send canceled by a platform admin"

  @type entry :: KilnCMS.Backups.Destination.entry()

  @type refusal ::
          :disabled
          | :invalid_stamp
          | :no_such_run
          | :not_partial
          | :no_dir_id
          | :unverified
          | :pruned
          | {:canceled_recently, pos_integer()}

  @doc "What the run's log says when a platform admin cancels its re-send."
  @spec canceled_note() :: String.t()
  def canceled_note, do: @canceled_note

  @doc "`:ok` while `BACKUP_ENABLED` is on, else `{:error, :disabled}` (O11)."
  @spec enabled() :: :ok | {:error, :disabled}
  def enabled, do: if(Backups.enabled?(), do: :ok, else: {:error, :disabled})

  @doc """
  The run of `stamp`, read as the `:backups` system actor: `{:ok, run}`,
  `{:error, :invalid_stamp}` for anything that is not a real stamp (checked
  before anything is read), `{:error, :no_such_run}`, or the read's error.
  """
  @spec fetch_run(term()) :: {:ok, Run.t()} | {:error, term()}
  def fetch_run(stamp) do
    if WorkState.valid_stamp?(stamp) do
      case Backups.get_run_by_stamp(stamp, actor: Backups.system(), authorize_with: :error) do
        {:ok, %Run{} = run} -> {:ok, run}
        {:ok, nil} -> {:error, :no_such_run}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_stamp}
    end
  end

  @doc """
  Whether `run` may be re-sent now (see "Which runs"): `:ok` or
  `{:error, refusal}`.
  """
  @spec eligible(Run.t(), DateTime.t()) :: :ok | {:error, refusal()}
  def eligible(%Run{} = run, now \\ DateTime.utc_now()) do
    with :ok <- enabled(),
         :ok <- offered(run),
         do: settled(run, now)
  end

  @doc """
  The checks of `eligible/2` that don't change with time or configuration:
  whether the History page offers Re-send for `run` at all.
  """
  @spec offered(Run.t()) :: :ok | {:error, refusal()}
  def offered(%Run{} = run) do
    cond do
      run.origin != :app or run.status != :succeeded -> {:error, :not_partial}
      Backups.run_offsite_state(run) not in [:partial, :failed] -> {:error, :not_partial}
      is_nil(run.dir_id) -> {:error, :no_dir_id}
      not verified?(run.artifacts) -> {:error, :unverified}
      Enum.any?(run.artifacts, &pruned_here?/1) -> {:error, :pruned}
      true -> :ok
    end
  end

  # Every artifact verified, and every file of it with a recorded digest:
  # nothing else can be re-checked before a copy.
  defp verified?([]), do: false

  defp verified?(artifacts) do
    Enum.all?(artifacts, &(&1.verified == true)) and
      Enum.all?(Artifact.output_entries(artifacts), &is_binary(&1.sha256))
  end

  defp pruned_here?(artifact) do
    local_pruned?(artifact.destinations) or
      Enum.any?(artifact.parts || [], &local_pruned?(&1["destinations"] || &1[:destinations]))
  end

  defp local_pruned?(%{"local" => %{"status" => "pruned"}}), do: true
  defp local_pruned?(_destinations), do: false

  # The newest "Re-send canceled" line on the run (`canceled_note/0`), as
  # `Backups.resumable_run/3` counts a Cancel's settle window from the run's
  # `finished_at`: a re-send's Cancel doesn't touch that.
  defp settled(run, now) do
    case last_cancel(run) do
      %DateTime{} = at ->
        left = Heartbeat.settled_after_ms() - DateTime.diff(now, at, :millisecond)
        if left > 0, do: {:error, {:canceled_recently, ceil(left / 1000)}}, else: :ok

      nil ->
        :ok
    end
  end

  defp last_cancel(%Run{log: log}) do
    log
    |> Enum.filter(&String.starts_with?(&1.message || "", @canceled_note))
    |> Enum.map(& &1.at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  @doc """
  Where a re-send of `run` goes, given the destinations configured now
  (`KilnCMS.Backups.Destination.configured/0`'s entries); see "Which
  destinations". `%{targets: entries, skipped: [%{key, label}], unreadable?:
  boolean}`: `targets` in the run's order, each as `configured/0` lists it;
  `unreadable?` when the run's `"unreadable"` entry was expanded into some of
  them and is to be replaced.
  """
  @spec targets(Run.t(), [entry()]) :: %{
          targets: [entry()],
          skipped: [%{key: String.t(), label: String.t() | nil}],
          unreadable?: boolean()
        }
  def targets(%Run{destinations: destinations}, configured) when is_list(configured) do
    ctx = %{
      by_key: Map.new(configured, &{&1["key"], &1}),
      known: MapSet.new(destinations, & &1.key),
      configured: configured
    }

    acc =
      destinations
      |> Enum.filter(&(&1.status in [:failed, :pending]))
      |> Enum.reduce(%{targets: [], skipped: [], unreadable?: false}, &target(&1, &2, ctx))

    %{acc | targets: Enum.uniq_by(acc.targets, & &1["key"])}
  end

  # The `"unreadable"` entry stands for the stored destinations enabled now
  # that the run has no entry for (O3); every other entry for itself.
  defp target(entry, acc, ctx) do
    cond do
      entry.key == RunDestination.unreadable_key() ->
        case Enum.filter(ctx.configured, &(&1["source"] == "db" and &1["key"] not in ctx.known)) do
          [] -> %{acc | skipped: acc.skipped ++ [skipped(entry)]}
          expanded -> %{acc | targets: acc.targets ++ expanded, unreadable?: true}
        end

      target = ctx.by_key[entry.key] ->
        %{acc | targets: acc.targets ++ [target]}

      true ->
        %{acc | skipped: acc.skipped ++ [skipped(entry)]}
    end
  end

  defp skipped(entry), do: %{key: entry.key, label: entry.label}

  @doc """
  The labels of the `targets` whose retention would delete `run` there at its
  next pass (#2949, critic change 15): a stored destination with `prune` on,
  when the run is older than `KilnCMS.Backups.keep_days/0`. The schedules'
  keep rules may hold it longer; this says "may". Read as the `:backups`
  system actor; a read that fails names none.
  """
  @spec pruned_soon(Run.t(), [entry()], DateTime.t()) :: [String.t()]
  def pruned_soon(%Run{started_at: started_at}, targets, now \\ DateTime.utc_now()) do
    old? = DateTime.diff(now, started_at, :day) > Backups.keep_days()
    ids = for %{"source" => "db", "id" => id} <- targets, do: id

    with true <- old? and ids != [],
         {:ok, rows} <-
           Backups.list_enabled_backup_destinations(
             actor: Backups.system(),
             authorize_with: :error
           ) do
      pruning = for row <- rows, row.prune, into: MapSet.new(), do: row.id

      for %{"source" => "db", "id" => id, "label" => label} <- targets,
          MapSet.member?(pruning, id),
          do: label
    else
      _ -> []
    end
  end

  @doc """
  The files a re-send of `run` copies, as `state.json`'s `"outputs"` holds
  them (string keys): `KilnCMS.Backups.Artifact.output_entries/1` of its
  artifacts. Their checksum sidecars are added by the off-site copy itself.
  """
  @spec outputs(Run.t()) :: [map()]
  def outputs(%Run{artifacts: artifacts}) do
    for entry <- Artifact.output_entries(artifacts),
        do: Map.new(entry, fn {k, v} -> {Atom.to_string(k), v} end)
  end
end
