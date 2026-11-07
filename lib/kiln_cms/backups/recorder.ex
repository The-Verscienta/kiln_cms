defmodule KilnCMS.Backups.Recorder do
  @moduledoc """
  The worker's side of a `KilnCMS.Backups.Run` (#2217): an explicit accumulator
  of what a backup has done so far, and the best-effort writes that persist it.

  The worker threads one `%Recorder{}` through its steps (no process
  dictionary): `log/4` and `add_artifact/2` only change the struct, while
  `progress/1`, `finish/1` and `fail/2` write it.

  ## Best-effort, always

  A backup is the product; its history row is a record of it. Every write here
  runs inside a boundary that turns a refusal, an error or a raise into a
  warning and carries on with the last row it had, so a failed Run write — a
  revoked grant, a lost connection, the row deleted by a database restore mid-run —
  never fails a good backup, and never deletes one. With no row (`run: nil`,
  after a stamp collision or a failed start) every call is a no-op.
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Redact}

  require Logger

  @type t :: %__MODULE__{
          run: KilnCMS.Backups.Run.t() | nil,
          components: [:db | :media],
          artifacts: [map()],
          log: [map()]
        }

  defstruct run: nil, components: [], artifacts: [], log: []

  @doc """
  Open the run for an attempt. On a stamp collision or any write error the
  attempt proceeds without a row.
  """
  @spec open(String.t(), String.t(), DateTime.t(), [:db | :media], integer() | nil) :: t()
  def open(stamp, trigger, started_at, components, job_id) do
    attrs = %{
      stamp: stamp,
      trigger: trigger,
      components: components,
      started_at: started_at,
      oban_job_id: job_id
    }

    case safely("open", fn -> Backups.start_run(attrs, actor: Backups.system()) end) do
      {:ok, run} -> %__MODULE__{run: run, components: components}
      _ -> %__MODULE__{components: components}
    end
  end

  @doc """
  Record a refused attempt (no `pg_dump`, backups disabled) as a `skipped` run.
  The manifest is not touched by the caller.
  """
  @spec skip(String.t(), String.t(), DateTime.t(), [:db | :media], String.t()) :: :ok
  def skip(stamp, trigger, started_at, components, reason) do
    attrs = %{
      stamp: stamp,
      trigger: trigger,
      components: components,
      started_at: started_at,
      error: reason
    }

    safely("skip", fn -> Backups.skip_run(attrs, actor: Backups.system()) end)
    :ok
  end

  @doc "Append a log line. Redaction and the length bound happen when it is written."
  @spec log(t(), :info | :warn | :error, String.t(), term()) :: t()
  def log(%__MODULE__{} = rec, level, step, message) do
    entry = %{at: DateTime.utc_now(), level: level, step: step, message: to_string(message)}
    %{rec | log: rec.log ++ [entry]}
  end

  @doc "Add a landed artifact, given as the worker's `%{kind, path, bytes, verified}` map."
  @spec add_artifact(t(), map()) :: t()
  def add_artifact(%__MODULE__{} = rec, artifact) do
    case Artifact.from_manifest(artifact) do
      {:ok, attrs} -> %{rec | artifacts: rec.artifacts ++ [attrs]}
      :error -> rec
    end
  end

  @doc """
  Set the status of one destination (`"rclone:<remote>"`) on the artifact called
  `name`. `error` is redacted and capped here.
  """
  @spec put_destination(t(), String.t(), String.t(), :ok | {:error, term()}) :: t()
  def put_destination(%__MODULE__{} = rec, name, key, result) do
    entry =
      case result do
        :ok ->
          %{"status" => "ok", "at" => now()}

        {:error, error} ->
          %{"status" => "failed", "at" => now(), "error" => Redact.text(error, [], 500)}
      end

    artifacts =
      for attrs <- rec.artifacts do
        if attrs.name == name,
          do: %{attrs | destinations: Map.put(attrs.destinations, key, entry)},
          else: attrs
      end

    %{rec | artifacts: artifacts}
  end

  @doc "Persist what has happened so far."
  @spec progress(t()) :: t()
  def progress(%__MODULE__{run: nil} = rec), do: rec

  def progress(%__MODULE__{} = rec),
    do: write(rec, "progress", &Backups.record_run_progress/3)

  @doc "Close the run as succeeded."
  @spec finish(t()) :: t()
  def finish(%__MODULE__{run: nil} = rec), do: rec
  def finish(%__MODULE__{} = rec), do: write(rec, "finish", &Backups.finish_run/3)

  @doc "Close the run as failed. `error` is redacted and capped when written."
  @spec fail(t(), String.t()) :: t()
  def fail(%__MODULE__{run: nil} = rec, _error), do: rec

  def fail(%__MODULE__{} = rec, error),
    do: write(rec, "fail", &Backups.fail_run/3, %{error: error})

  @doc """
  Mark `local` as `pruned` on the artifacts of OTHER runs whose files the
  retention sweep just deleted (`names` are file names). Best-effort per run.
  """
  @spec mark_pruned([String.t()]) :: :ok
  def mark_pruned(names) do
    at = now()

    names
    |> Enum.group_by(fn name ->
      with {:ok, _kind, stamp, false} <- Artifact.parse_name(name), do: stamp
    end)
    |> Enum.each(fn
      {stamp, stamp_names} when is_binary(stamp) -> mark_run_pruned(stamp, stamp_names, at)
      _unparsed -> :ok
    end)
  end

  defp mark_run_pruned(stamp, names, at) do
    safely("prune", fn ->
      with {:ok, %{} = run} <- Backups.get_run_by_stamp(stamp, actor: Backups.system()) do
        artifacts = Enum.map(run.artifacts, &prune_artifact(&1, names, at))
        Backups.record_run_progress(run, %{artifacts: artifacts}, actor: Backups.system())
      end
    end)

    :ok
  end

  @artifact_fields [:kind, :name, :bytes, :sha256, :verified, :parts, :encrypted?, :destinations]

  defp prune_artifact(artifact, names, at) do
    attrs = Map.take(artifact, @artifact_fields)

    if artifact.name in names do
      pruned = %{"status" => "pruned", "at" => at}
      %{attrs | destinations: Map.put(attrs.destinations, "local", pruned)}
    else
      attrs
    end
  end

  defp write(rec, label, fun, extra \\ %{}) do
    params =
      Map.merge(%{components: rec.components, artifacts: rec.artifacts, log: rec.log}, extra)

    case safely(label, fn -> fun.(rec.run, params, actor: Backups.system()) end) do
      {:ok, run} -> %{rec | run: run}
      _ -> rec
    end
  end

  # The boundary: a write that is refused, errors or raises is a warning, and
  # the caller carries on. Returns the write's result, or `{:error, _}`.
  defp safely(label, fun) do
    case fun.() do
      {:error, error} = result ->
        warn(label, error)
        result

      result ->
        result
    end
  rescue
    error ->
      warn(label, error)
      {:error, error}
  catch
    kind, reason ->
      warn(label, {kind, reason})
      {:error, {kind, reason}}
  end

  defp warn(label, error) do
    detail = error |> inspect(limit: 5, printable_limit: 300) |> Redact.text([], 300)

    Logger.warning(
      "Backup run record (#{label}) not written — the backup itself is unaffected: #{detail}"
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
