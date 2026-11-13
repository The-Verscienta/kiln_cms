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

  ## Across the step chain (#2218)

  Each step of a chain is its own job, so the accumulator travels between them
  in `state.json` (`to_state/1`, `load/3`), which a step must write, rather than
  in the Run row, which is best-effort: a step that missed a Run write still
  hands the next step everything, and the run is closed from that. A step only
  writes a Run whose `chain_id` is its own chain's, and the UPDATE enforces it
  (`KilnCMS.Backups.Run.Changes.OwnChain`, #2538): a step that outlived its
  Cancel can't write over a resume of the same run.
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Redact}

  require Logger

  @type t :: %__MODULE__{
          run: KilnCMS.Backups.Run.t() | nil,
          chain_id: String.t() | nil,
          dir_id: String.t() | nil,
          components: [:db | :media],
          artifacts: [map()],
          log: [map()]
        }

  @artifact_fields [:kind, :name, :bytes, :sha256, :verified, :parts, :encrypted?, :destinations]

  defstruct run: nil, chain_id: nil, dir_id: nil, components: [], artifacts: [], log: []

  @doc """
  Open the run for an attempt. On a stamp collision or any write error the
  attempt proceeds without a row.

  With a `chain_id`, a run this chain already opened under `stamp` (the start
  step retried) is taken up again instead of colliding with itself. `extra`
  may carry `scheduled_components` and `schedule_ids` (#2219), and `dir_id`,
  the directory the run's files go to (#2539), which `progress/1` records
  again, so a start retried on another node rebinds it.
  """
  @spec open(
          String.t(),
          String.t(),
          DateTime.t(),
          [:db | :media],
          integer() | nil,
          String.t() | nil,
          map()
        ) ::
          t()
  def open(stamp, trigger, started_at, components, job_id, chain_id \\ nil, extra \\ %{}) do
    attrs =
      Map.merge(Map.take(extra, [:scheduled_components, :schedule_ids, :dir_id]), %{
        stamp: stamp,
        trigger: trigger,
        components: components,
        started_at: started_at,
        oban_job_id: job_id,
        chain_id: chain_id
      })

    rec = %__MODULE__{components: components, chain_id: chain_id, dir_id: extra[:dir_id]}

    case own_run(stamp, chain_id) do
      %{} = run -> %{rec | run: run}
      nil -> start_run(rec, attrs)
    end
  end

  defp start_run(rec, attrs) do
    case safely("open", fn -> Backups.start_run(attrs, actor: Backups.system()) end) do
      {:ok, run} -> %{rec | run: run}
      _ -> rec
    end
  end

  @doc """
  The recorder a later step of `chain_id` works with: the accumulator `saved`
  in `state.json` (`to_state/1`), writing to the run of `stamp` only if that
  run belongs to this chain. Never fails; with no such run the writes are
  no-ops.
  """
  @spec load(String.t(), String.t(), map() | nil) :: t()
  def load(stamp, chain_id, saved) do
    saved
    |> from_state()
    |> Map.merge(%{chain_id: chain_id, run: own_run(stamp, chain_id)})
  end

  @doc """
  A recorder seeded from the run row of `stamp` itself, for a chain whose
  `state.json` is gone: closing the run from it keeps what the row already
  holds rather than overwriting it with nothing.
  """
  @spec from_run(String.t() | nil, String.t()) :: t()
  def from_run(nil, chain_id), do: %__MODULE__{chain_id: chain_id}

  def from_run(stamp, chain_id) do
    case own_run(stamp, chain_id) do
      nil ->
        %__MODULE__{chain_id: chain_id}

      run ->
        %__MODULE__{
          run: run,
          chain_id: chain_id,
          components: run.components,
          artifacts: Enum.map(run.artifacts, &Map.take(&1, @artifact_fields)),
          log: Enum.map(run.log, &Map.take(&1, [:at, :level, :step, :message]))
        }
    end
  end

  defp own_run(_stamp, nil), do: nil

  defp own_run(stamp, chain_id) do
    case safely("load", fn -> Backups.get_run_by_stamp(stamp, actor: Backups.system()) end) do
      {:ok, %{chain_id: ^chain_id} = run} -> run
      _ -> nil
    end
  end

  @doc "The accumulator as JSON-safe data for `state.json`; `load/3` reads it back."
  @spec to_state(t()) :: map()
  def to_state(%__MODULE__{} = rec) do
    %{
      "components" => Enum.map(rec.components, &Atom.to_string/1),
      "artifacts" => rec.artifacts,
      "log" =>
        Enum.map(rec.log, fn entry ->
          %{
            "at" => entry.at,
            "level" => to_string(entry.level),
            "step" => entry.step,
            "message" => entry.message
          }
        end)
    }
  end

  @artifact_keys ~w(kind name bytes sha256 verified parts encrypted? destinations part parts_total oversize)
  @levels ~w(info warn error)

  defp from_state(%{} = saved) do
    %__MODULE__{
      components:
        for(
          c <- List.wrap(saved["components"]),
          c in ["db", "media"],
          do: String.to_existing_atom(c)
        ),
      artifacts: for(a <- List.wrap(saved["artifacts"]), is_map(a), do: decode_artifact(a)),
      log: for(e <- List.wrap(saved["log"]), is_map(e), do: decode_entry(e))
    }
  end

  defp from_state(_none), do: %__MODULE__{}

  defp decode_artifact(map) do
    for {key, value} <- map, key = to_string(key), key in @artifact_keys, into: %{} do
      case key do
        "kind" -> {:kind, if(value in ["db", :db], do: :db, else: :media)}
        key -> {String.to_existing_atom(key), value}
      end
    end
  end

  defp decode_entry(entry) do
    at =
      case entry["at"] do
        %DateTime{} = at ->
          at

        text when is_binary(text) ->
          case DateTime.from_iso8601(text) do
            {:ok, at, _} -> at
            _ -> DateTime.utc_now()
          end

        _ ->
          DateTime.utc_now()
      end

    level = if entry["level"] in @levels, do: String.to_existing_atom(entry["level"]), else: :info
    %{at: at, level: level, step: to_string(entry["step"]), message: to_string(entry["message"])}
  end

  @doc """
  Re-open the run for `stamp` as `running` (#2218), through its `:resume` action:
  a failed (or stale-running) in-app run goes back to work with its old outcome
  cleared, and the accumulator starts from the run's existing log so the history
  keeps the first attempt's lines and gains the resume.

  `dir_id` is the directory the resume read `state.json` from (#2539): the
  run is rebound to it, which also back-fills a run from before #2539.

  Unlike every other call here this one reports `{:error, reason}`: the caller
  must refuse the resume when the run can't be re-opened (it is no longer
  failed, the grant is revoked, the row is gone), not carry on without a row.
  """
  @spec reopen(String.t(), String.t() | nil, String.t() | nil) :: {:ok, t()} | {:error, term()}
  def reopen(stamp, chain_id \\ nil, dir_id \\ nil) do
    result =
      safely("reopen", fn ->
        with {:ok, %{} = run} <- Backups.get_run_by_stamp(stamp, actor: Backups.system()) do
          Backups.resume_run(run, resume_params(chain_id, dir_id), actor: Backups.system())
        end
      end)

    case result do
      {:ok, %{} = run} -> {:ok, resumed(run, chain_id)}
      _ -> {:error, :not_resumable}
    end
  end

  # A nil `dir_id` keeps the run's own: it is not evidence of anything.
  defp resume_params(chain_id, nil), do: %{chain_id: chain_id}
  defp resume_params(chain_id, dir_id), do: %{chain_id: chain_id, dir_id: dir_id}

  @doc """
  The accumulator for a run that chain `chain_id` already re-opened
  (`reopen/3`): a resume's start step retried after the re-open committed but
  before its `state.json` landed. `{:error, :not_resumable}` unless the run is
  `running` under `chain_id`.
  """
  @spec reopened(String.t(), String.t()) :: {:ok, t()} | {:error, :not_resumable}
  def reopened(stamp, chain_id) do
    case own_run(stamp, chain_id) do
      %{status: :running} = run -> {:ok, resumed(run, chain_id)}
      _ -> {:error, :not_resumable}
    end
  end

  defp resumed(run, chain_id) do
    %__MODULE__{
      run: run,
      chain_id: chain_id,
      dir_id: run.dir_id,
      components: run.components,
      artifacts: [],
      log: Enum.map(run.log, &Map.take(&1, [:at, :level, :step, :message]))
    }
  end

  @doc """
  Say on the run of `stamp` that a resume of it was refused (#2539), through
  its `:note_resume_refused` action: for a resume that never re-opened the run
  (its files aren't on the node that picked it up, it gave up waiting for a
  node that has them). The run keeps its status, so it stays resumable; a
  stale `running` one is failed. Best-effort: a run that is live, imported,
  succeeded or gone is left alone, with a warning.
  """
  @spec resume_refused(String.t(), String.t()) :: :ok
  def resume_refused(stamp, message) do
    safely("resume refused", fn ->
      with {:ok, %{} = run} <- Backups.get_run_by_stamp(stamp, actor: Backups.system()) do
        Backups.note_run_resume_refused(run, message, actor: Backups.system())
      end
    end)

    :ok
  end

  @doc """
  Record a refused attempt (no `pg_dump`, backups disabled) as a `skipped` run.
  The manifest is not touched by the caller. `extra` as `open/7`.
  """
  @spec skip(String.t(), String.t(), DateTime.t(), [:db | :media], String.t(), map()) :: :ok
  def skip(stamp, trigger, started_at, components, reason, extra \\ %{}) do
    attrs =
      Map.merge(Map.take(extra, [:scheduled_components, :schedule_ids]), %{
        stamp: stamp,
        trigger: trigger,
        components: components,
        started_at: started_at,
        error: reason
      })

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
  Set the status of one destination (`"rclone:<remote>"`) for the file called
  `name`. `error` is redacted and capped here.

  `name` is a single-file artifact's name, or the name of one PART of a media
  set (the artifact itself is the logical `kiln-media-<stamp>`; see
  `Artifact.files/1`). A part's result lands on the part, and the artifact's own
  destination is re-derived from all its parts, as `Artifact.group_files/1`
  does: `ok` only when every part reached the destination, else the first part
  that did not (a part not attempted yet leaves it `pending`).
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
        cond do
          attrs.name == name ->
            %{attrs | destinations: Map.put(attrs.destinations, key, entry)}

          Map.get(attrs, :parts, []) != [] and name in Artifact.files(attrs) ->
            put_part_destination(attrs, name, key, entry)

          true ->
            attrs
        end
      end

    %{rec | artifacts: artifacts}
  end

  defp put_part_destination(attrs, name, key, entry) do
    parts =
      Enum.map(attrs.parts, fn part ->
        if part["name"] == name,
          do: Map.update(part, "destinations", %{key => entry}, &Map.put(&1, key, entry)),
          else: part
      end)

    %{
      attrs
      | parts: parts,
        destinations: Map.put(attrs.destinations, key, aggregate(parts, key))
    }
  end

  defp aggregate(parts, key) do
    entries = for part <- parts, entry = get_in(part, ["destinations", key]), do: entry

    cond do
      failing = Enum.find(entries, &(&1["status"] != "ok")) -> failing
      length(entries) == length(parts) -> List.last(entries)
      true -> %{"status" => "pending"}
    end
  end

  @doc """
  Mark the artifact holding the file called `name` as not verified (#2218): a
  file whose off-site copy was refused because it changed on disk after the
  backup verified it. `name` is a single-file artifact's name or one part of a
  media set, which marks the whole set (a set is verified only if every part
  is). Unknown names change nothing.
  """
  @spec put_unverified(t(), String.t()) :: t()
  def put_unverified(%__MODULE__{} = rec, name) do
    artifacts =
      for attrs <- rec.artifacts do
        if attrs.name == name or name in Artifact.files(attrs),
          do: %{attrs | verified: false},
          else: attrs
      end

    %{rec | artifacts: artifacts}
  end

  @doc "Persist what has happened so far."
  @spec progress(t()) :: t()
  def progress(%__MODULE__{run: nil} = rec), do: rec

  def progress(%__MODULE__{dir_id: nil} = rec),
    do: write(rec, "progress", &Backups.record_run_progress/3)

  def progress(%__MODULE__{} = rec),
    do: write(rec, "progress", &Backups.record_run_progress/3, %{dir_id: rec.dir_id})

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

  A media set's parts are one artifact: each deleted part is marked, and the
  artifact itself once none of its files is left to mark. Names that are not
  artifacts (a checksum sidecar) are ignored.
  """
  @spec mark_pruned([String.t()]) :: :ok
  def mark_pruned(names) do
    at = now()

    names
    |> Enum.group_by(fn name ->
      with {:ok, %{stamp: stamp}} <- Artifact.parse_file(name), do: stamp
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
        Backups.mark_run_pruned(run, %{artifacts: artifacts}, actor: Backups.system())
      end
    end)

    :ok
  end

  defp prune_artifact(artifact, names, at) do
    attrs = Map.take(artifact, @artifact_fields)
    pruned = %{"status" => "pruned", "at" => at}

    case attrs.parts do
      [] ->
        if artifact.name in names, do: put_local(attrs, pruned), else: attrs

      parts ->
        prune_parts(attrs, parts, names, pruned)
    end
  end

  defp prune_parts(attrs, parts, names, pruned) do
    parts =
      Enum.map(parts, fn part ->
        if part["name"] in names, do: put_local_part(part, pruned), else: part
      end)

    attrs = %{attrs | parts: parts}
    if Enum.all?(parts, &local_pruned?/1), do: put_local(attrs, pruned), else: attrs
  end

  defp put_local(attrs, pruned),
    do: %{attrs | destinations: Map.put(attrs.destinations, "local", pruned)}

  defp put_local_part(part, pruned) do
    Map.update(part, "destinations", %{"local" => pruned}, &Map.put(&1, "local", pruned))
  end

  defp local_pruned?(part), do: get_in(part, ["destinations", "local", "status"]) == "pruned"

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
