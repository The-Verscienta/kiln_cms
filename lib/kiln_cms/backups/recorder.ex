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

  ## Off-site destinations (#2220)

  `destinations` is the Run-level summary, one entry per off-site destination
  (`KilnCMS.Backups.RunDestination`), upserted by key with
  `put_run_destination/3`. Like `artifacts`, every Run write re-sends it whole
  and it travels in `state.json`. `finish/1` and `fail/2` record the
  `offsite_status` that `offsite_outcome/1` derives from it.
  """
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{Artifact, Redact, RunDestination}

  require Logger

  @type t :: %__MODULE__{
          run: KilnCMS.Backups.Run.t() | nil,
          chain_id: String.t() | nil,
          dir_id: String.t() | nil,
          components: [:db | :media],
          artifacts: [map()],
          log: [map()],
          destinations: [run_destination()]
        }

  @typedoc "A Run-level destination entry, as `KilnCMS.Backups.RunDestination` takes it."
  @type run_destination :: %{
          required(:key) => String.t(),
          optional(:kind) => String.t() | nil,
          optional(:label) => String.t() | nil,
          optional(:status) => :pending | :ok | :failed | :skipped,
          optional(:error) => String.t() | nil,
          optional(:at) => DateTime.t() | nil,
          optional(:files_ok) => non_neg_integer(),
          optional(:files_total) => non_neg_integer(),
          optional(:pruned) => non_neg_integer()
        }

  @type offsite_outcome :: :none | :complete | :partial | :failed | :unknown

  @artifact_fields [:kind, :name, :bytes, :sha256, :verified, :parts, :encrypted?, :destinations]

  @destination_fields [
    :key,
    :kind,
    :label,
    :status,
    :error,
    :at,
    :files_ok,
    :files_total,
    :pruned
  ]
  @destination_statuses RunDestination.statuses()

  defstruct run: nil,
            chain_id: nil,
            dir_id: nil,
            components: [],
            artifacts: [],
            log: [],
            destinations: []

  @doc """
  Open the run for an attempt. On a stamp collision or any write error the
  attempt proceeds without a row.

  With a `chain_id`, a run this chain already opened under `stamp` (the start
  step retried) is taken up again instead of colliding with itself. `extra`
  may carry `scheduled_components` and `schedule_ids` (#2219), and `dir_id`,
  the directory the run's files go to (#2539), which `progress/1` records
  again, so a start retried on another node rebinds it, and `destinations`,
  the Run-level off-site entries the start settled (#2220).
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
    destinations = Enum.map(Map.get(extra, :destinations, []), &destination_entry/1)

    attrs =
      Map.merge(Map.take(extra, [:scheduled_components, :schedule_ids, :dir_id]), %{
        stamp: stamp,
        trigger: trigger,
        components: components,
        started_at: started_at,
        oban_job_id: job_id,
        chain_id: chain_id,
        destinations: destinations
      })

    rec = %__MODULE__{
      components: components,
      chain_id: chain_id,
      dir_id: extra[:dir_id],
      destinations: destinations
    }

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
          log: Enum.map(run.log, &Map.take(&1, [:at, :level, :step, :message])),
          destinations: Enum.map(run.destinations, &stored_destination/1)
        }
    end
  end

  # A loaded entry back into the accumulator's shape. A status this release
  # doesn't know (`UnknownAtom`) is written back as `pending`: input refuses
  # the struct, and nothing here may claim the destination was reached.
  defp stored_destination(%RunDestination{} = entry) do
    entry
    |> Map.take(@destination_fields)
    |> Map.update!(:status, &known_status/1)
  end

  defp known_status(status) when status in @destination_statuses, do: status
  defp known_status(_unknown), do: :pending

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
        end),
      "destinations" =>
        Enum.map(rec.destinations, fn entry ->
          for {key, value} <- entry, into: %{} do
            {Atom.to_string(key), if(key == :status, do: Atom.to_string(value), else: value)}
          end
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
      log: for(e <- List.wrap(saved["log"]), is_map(e), do: decode_entry(e)),
      destinations:
        for(
          d <- List.wrap(saved["destinations"]),
          is_map(d),
          is_binary(d["key"]),
          do: decode_destination(d)
        )
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

  @destination_keys Enum.map(@destination_fields, &Atom.to_string/1)
  @destination_status_names Enum.map(@destination_statuses, &Atom.to_string/1)

  # Only the known fields; a status this release doesn't know reads as
  # `pending`, never as reached.
  defp decode_destination(map) do
    for {key, value} <- map, key in @destination_keys, into: %{} do
      case key do
        "status" ->
          {:status,
           if(value in @destination_status_names,
             do: String.to_existing_atom(value),
             else: :pending
           )}

        "at" ->
          {:at, decode_time(value, nil)}

        key ->
          {String.to_existing_atom(key), value}
      end
    end
  end

  defp decode_entry(entry) do
    at = decode_time(entry["at"], DateTime.utc_now())

    level = if entry["level"] in @levels, do: String.to_existing_atom(entry["level"]), else: :info
    %{at: at, level: level, step: to_string(entry["step"]), message: to_string(entry["message"])}
  end

  defp decode_time(%DateTime{} = at, _default), do: at

  defp decode_time(text, default) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} -> at
      _ -> default
    end
  end

  defp decode_time(_other, default), do: default

  @doc """
  Re-open the run for `stamp` as `running` (#2218), through its `:resume` action:
  a failed (or stale-running) in-app run goes back to work with its old outcome
  cleared, and the accumulator starts from the run's existing log so the history
  keeps the first attempt's lines and gains the resume.

  `dir_id` is the directory the resume read `state.json` from (#2539): the
  run is rebound to it, which also back-fills a run from before #2539.

  The run's off-site outcome is cleared with it (#2220): the resume's start
  settles the destinations again.

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
      log: Enum.map(run.log, &Map.take(&1, [:at, :level, :step, :message])),
      destinations: []
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
  Upsert the Run-level entry for the off-site destination `key` (#2220):
  `attrs` (any of `kind`, `label`, `status`, `error`, `at`, `files_ok`,
  `files_total`, `pruned`) are merged into the entry with that key, or a new
  entry is appended (status `pending` unless given). A status given without
  `at` is stamped now. `error` and `label` are redacted and capped here, and
  again when written.
  """
  @spec put_run_destination(t(), String.t(), map() | keyword()) :: t()
  def put_run_destination(%__MODULE__{} = rec, key, attrs) when is_binary(key) do
    attrs = attrs |> Map.new() |> Map.take(@destination_fields -- [:key])

    attrs =
      if Map.has_key?(attrs, :status) and not Map.has_key?(attrs, :at),
        do: Map.put(attrs, :at, DateTime.utc_now()),
        else: attrs

    destinations =
      if Enum.any?(rec.destinations, &(&1.key == key)),
        do: Enum.map(rec.destinations, &merge_destination(&1, key, attrs)),
        else: rec.destinations ++ [destination_entry(Map.put(attrs, :key, key))]

    %{rec | destinations: destinations}
  end

  defp merge_destination(%{key: key} = entry, key, attrs),
    do: destination_entry(Map.merge(entry, attrs))

  defp merge_destination(entry, _key, _attrs), do: entry

  # An entry in the accumulator's shape: the known fields, the defaults the
  # embedded resource would give, and `error`/`label` scrubbed.
  defp destination_entry(%{} = attrs) do
    %{key: to_string(attrs[:key]), status: :pending, files_ok: 0, files_total: 0, pruned: 0}
    |> Map.merge(Map.take(attrs, @destination_fields -- [:key]))
    |> scrub(:error, 500)
    |> scrub(:label, 200)
  end

  defp scrub(entry, field, max) do
    case Map.get(entry, field) do
      text when is_binary(text) -> Map.put(entry, field, Redact.text(text, [], max))
      _none -> entry
    end
  end

  @doc """
  What a run's off-site destinations add up to (#2220), from its Run-level
  entries (maps or `KilnCMS.Backups.RunDestination`s):

    * `:none` - no destination (entries marked `skipped` don't count);
    * `:complete` - every destination is `ok`;
    * `:failed` - no destination is `ok` and every one that could be read
      `failed`;
    * `:unknown` - every destination is still `pending`: nothing was
      settled. A running backup's off-site step hasn't reached them yet; a
      finished run like that was closed by a release from before #2220,
      whose off-site step and finish don't record destinations (critic
      change 12), so it must not read as "still sending". Never written as
      a Run's `offsite_status`: `finish/1` and `fail/2` leave it nil;
    * `:partial` - anything else: some `ok` and some not, a destination still
      `pending` (or in a status this release doesn't know) beside a settled
      one, or the `RunDestination.unreadable_key/0` entry, which never counts
      as complete: the destinations it stands for may not have been sent to.
  """
  @spec offsite_outcome([run_destination() | RunDestination.t()]) :: offsite_outcome()
  def offsite_outcome(destinations) when is_list(destinations) do
    unreadable = RunDestination.unreadable_key()
    counted = Enum.reject(destinations, &(&1.status == :skipped))
    {fenced, real} = Enum.split_with(counted, &(&1.key == unreadable))
    statuses = Enum.map(real, & &1.status)

    cond do
      counted == [] -> :none
      fenced == [] and Enum.all?(statuses, &(&1 == :pending)) -> :unknown
      fenced == [] and Enum.all?(statuses, &(&1 == :ok)) -> :complete
      real != [] and Enum.all?(statuses, &(&1 == :failed)) -> :failed
      true -> :partial
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

  @doc """
  Close the run as succeeded, with the `offsite_status` its destinations add
  up to (`offsite_outcome/1`; nil while it is `:unknown`).
  """
  @spec finish(t()) :: t()
  def finish(%__MODULE__{run: nil} = rec), do: rec

  def finish(%__MODULE__{} = rec) do
    offsite =
      case offsite_outcome(rec.destinations) do
        :unknown -> nil
        settled -> settled
      end

    write(rec, "finish", &Backups.finish_run/3, %{offsite_status: offsite})
  end

  @doc """
  Close the run as failed. `error` is redacted and capped when written.

  `offsite_status` is recorded only when it is settled: `:failed` when every
  destination failed, `:none` when there is none. A run that failed before
  its destinations were all tried leaves it nil: there is nothing to say
  about an off-site copy that never ran to the end.
  """
  @spec fail(t(), String.t()) :: t()
  def fail(%__MODULE__{run: nil} = rec, _error), do: rec

  def fail(%__MODULE__{} = rec, error) do
    offsite =
      case offsite_outcome(rec.destinations) do
        settled when settled in [:failed, :none] -> settled
        _unsettled -> nil
      end

    write(rec, "fail", &Backups.fail_run/3, %{error: error, offsite_status: offsite})
  end

  @doc """
  Mark `key` as `pruned` on the artifacts of OTHER runs whose files a
  retention pass just deleted there (`names` are file names): `"local"` for
  this host's backup directory (the default), or a destination's key for
  retention on that destination (#2220). Best-effort per run, through the
  run's `:mark_pruned` action.

  A media set's parts are one artifact: each deleted part is marked, and the
  artifact itself once none of its files is left to mark. Names that are not
  artifacts (a checksum sidecar) are ignored.
  """
  @spec mark_pruned([String.t()], String.t()) :: :ok
  def mark_pruned(names, key \\ "local") when is_binary(key) do
    at = now()

    names
    |> Enum.group_by(fn name ->
      with {:ok, %{stamp: stamp}} <- Artifact.parse_file(name), do: stamp
    end)
    |> Enum.each(fn
      {stamp, stamp_names} when is_binary(stamp) -> mark_run_pruned(stamp, stamp_names, key, at)
      _unparsed -> :ok
    end)
  end

  defp mark_run_pruned(stamp, names, key, at) do
    safely("prune", fn ->
      with {:ok, %{} = run} <- Backups.get_run_by_stamp(stamp, actor: Backups.system()) do
        artifacts = Enum.map(run.artifacts, &prune_artifact(&1, names, key, at))
        Backups.mark_run_pruned(run, %{artifacts: artifacts}, actor: Backups.system())
      end
    end)

    :ok
  end

  defp prune_artifact(artifact, names, key, at) do
    attrs = Map.take(artifact, @artifact_fields)
    pruned = %{"status" => "pruned", "at" => at}

    case attrs.parts do
      [] ->
        if artifact.name in names, do: put_pruned(attrs, key, pruned), else: attrs

      parts ->
        prune_parts(attrs, parts, names, key, pruned)
    end
  end

  defp prune_parts(attrs, parts, names, key, pruned) do
    parts =
      Enum.map(parts, fn part ->
        if part["name"] in names, do: put_part_pruned(part, key, pruned), else: part
      end)

    attrs = %{attrs | parts: parts}
    if Enum.all?(parts, &part_pruned?(&1, key)), do: put_pruned(attrs, key, pruned), else: attrs
  end

  defp put_pruned(attrs, key, pruned),
    do: %{attrs | destinations: Map.put(attrs.destinations, key, pruned)}

  defp put_part_pruned(part, key, pruned) do
    Map.update(part, "destinations", %{key => pruned}, &Map.put(&1, key, pruned))
  end

  defp part_pruned?(part, key), do: get_in(part, ["destinations", key, "status"]) == "pruned"

  defp write(rec, label, fun, extra \\ %{}) do
    params =
      Map.merge(
        %{
          components: rec.components,
          artifacts: rec.artifacts,
          log: rec.log,
          destinations: rec.destinations
        },
        extra
      )

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
