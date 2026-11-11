defmodule KilnCMS.Backups.WorkState do
  @moduledoc """
  The durable state of one in-flight backup (#2218): what a resume needs to pick
  up where a failed run stopped.

  It lives in `<BACKUP_DIR>/.work/<stamp>/state.json` next to the media planner's
  lists (`MediaArchive`; `plan.json` is the plan's commit marker). The directory
  is 0700 and `state.json` is 0600, written atomically (`.partial`, then
  rename), so a crash leaves either the previous state or the next, never half
  of one.

  The file records which steps have completed and, for the database dump and for
  each finished media part, its `{name, bytes, sha256}`. **A recorded hash is the
  only licence to reuse a file**: the worker reuses a dump or part only when this
  file recorded its digest *and* `Checksum.verify/2` matches the bytes on disk.
  A final-named file with no entry (or a different digest) is rebuilt, never
  trusted because it happens to exist.

  The file is a hint to a resume and a record of work already done, not a source
  of truth for *permission*: the Run row (not this file) decides whether a resume
  is permitted at all.

  ## Version 2: the step chain's state (#2218)

  Since the pipeline became a chain of Oban jobs (`KilnCMS.Backups.StepWorker`),
  this file is also how one step hands its results to the next, so writing it
  is no longer best-effort: a step whose state write fails is retried. Version 2
  adds `chain` (the chain that owns the directory), `trigger`, `started_at`,
  `resume`, `dir_id`, `components`, `parts_total`, `outputs` (the manifest
  entries landed so far), `offsite` and `rec` (the run record's accumulator,
  `KilnCMS.Backups.Recorder.to_state/1`). A version-1 file, written by a release
  before the chain, still reads: a resume of it stamps the chain into it.

  `path/2` is the one place a path is built from a stamp, and it refuses anything
  that is not a real `YYYYMMDD-HHMMSS` instant, so a forged stamp cannot walk out
  of `.work`.
  """
  alias KilnCMS.Backups.Artifact

  @stamp ~r/\A\d{8}-\d{6}\z/
  @version 2

  @type t :: %{required(String.t()) => term()}

  @doc "Whether `stamp` is a real `YYYYMMDD-HHMMSS` stamp (and so safe in a path)."
  @spec valid_stamp?(term()) :: boolean()
  def valid_stamp?(stamp) when is_binary(stamp) do
    Regex.match?(@stamp, stamp) and match?({:ok, _}, Artifact.parse_stamp(stamp))
  end

  def valid_stamp?(_other), do: false

  @doc """
  The work directory of `stamp` under the backup directory `dir`.

  Raises `ArgumentError` for a stamp `valid_stamp?/1` refuses: no path is ever
  built from one.
  """
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(dir, stamp) do
    unless valid_stamp?(stamp), do: raise(ArgumentError, "invalid backup stamp")
    Path.join([dir, ".work", stamp])
  end

  @doc "The state file inside a work directory."
  @spec file(Path.t()) :: Path.t()
  def file(work_dir), do: Path.join(work_dir, "state.json")

  @doc "Whether a work directory holds a state file."
  @spec exists?(Path.t()) :: boolean()
  def exists?(work_dir), do: File.regular?(file(work_dir))

  @doc "A fresh state for `stamp`, with the chain's own `fields` (string keys) merged in."
  @spec new(String.t(), map()) :: t()
  def new(stamp, fields \\ %{}) do
    Map.merge(
      %{"version" => @version, "stamp" => stamp, "steps" => [], "dump" => nil, "parts" => %{}},
      fields
    )
  end

  @doc "The chain that owns this state, or `nil` (a version-1 file)."
  @spec chain(t()) :: String.t() | nil
  def chain(state), do: Map.get(state, "chain")

  @doc """
  Read the state of a work directory. `{:error, :no_state}` when the file is
  missing, unreadable or not a state this module wrote.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec read(Path.t()) :: {:ok, t()} | {:error, :no_state}
  def read(work_dir) do
    with {:ok, json} <- File.read(file(work_dir)),
         {:ok, %{"stamp" => stamp, "steps" => steps, "parts" => parts} = state}
         when is_binary(stamp) and is_list(steps) and is_map(parts) <- Jason.decode(json) do
      {:ok, state}
    else
      _ -> {:error, :no_state}
    end
  end

  @doc "Write `state` atomically (`.partial` then rename), mode 0600."
  # sobelow_skip ["Traversal.FileModule"]
  @spec write(Path.t(), t()) :: :ok | {:error, term()}
  def write(work_dir, state) do
    path = file(work_dir)
    tmp = path <> ".partial"

    with {:ok, json} <- Jason.encode(state),
         :ok <- File.write(tmp, json),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _} = error ->
        File.rm(tmp)
        error
    end
  end

  @doc """
  Read-modify-write: apply `fun` to the current state (a fresh one when the file
  is missing) and write the result.
  """
  @spec update(Path.t(), String.t(), (t() -> t())) :: :ok | {:error, term()}
  def update(work_dir, stamp, fun) do
    state =
      case read(work_dir) do
        {:ok, state} -> state
        {:error, :no_state} -> new(stamp)
      end

    write(work_dir, fun.(state))
  end

  @doc "Mark `step` complete."
  @spec complete(t(), String.t()) :: t()
  def complete(state, step), do: Map.update(state, "steps", [step], &Enum.uniq(&1 ++ [step]))

  @doc "Whether `step` is recorded as complete."
  @spec completed?(t(), String.t()) :: boolean()
  def completed?(state, step), do: step in Map.get(state, "steps", [])

  @doc "Record the database dump's `{name, bytes, sha256}`."
  @spec put_dump(t(), %{name: String.t(), bytes: non_neg_integer(), sha256: String.t()}) :: t()
  def put_dump(state, %{name: name, bytes: bytes, sha256: sha256}),
    do: Map.put(state, "dump", entry(name, bytes, sha256))

  @doc "The recorded dump entry, or `nil`."
  @spec dump(t()) :: map() | nil
  def dump(state), do: valid_entry(Map.get(state, "dump"))

  @doc "Record a finished media part (a `MediaArchive` finished map)."
  @spec put_part(t(), map()) :: t()
  def put_part(state, %{index: index, name: name, bytes: bytes, sha256: sha256} = finished) do
    entry =
      name
      |> entry(bytes, sha256)
      |> Map.merge(%{"oversize" => finished[:oversize] == true, "files" => finished[:files]})

    Map.update(state, "parts", %{}, &Map.put(&1, Integer.to_string(index), entry))
  end

  @doc "The recorded entry of part `index`, or `nil`."
  @spec part(t(), pos_integer()) :: map() | nil
  def part(state, index),
    do: state |> Map.get("parts", %{}) |> Map.get(Integer.to_string(index)) |> valid_entry()

  @doc "Forget every recorded part (the plan they belonged to is gone)."
  @spec clear_parts(t()) :: t()
  def clear_parts(state),
    do:
      state
      |> Map.put("parts", %{})
      |> Map.update("steps", [], &(&1 -- ["plan", "archive", "checksum"]))

  defp entry(name, bytes, sha256) do
    %{
      "name" => name,
      "bytes" => bytes,
      "sha256" => sha256,
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  # Only an entry with a name, an integer size and a digest can license a reuse.
  defp valid_entry(%{"name" => name, "bytes" => bytes, "sha256" => sha256} = entry)
       when is_binary(name) and is_integer(bytes) and is_binary(sha256),
       do: entry

  defp valid_entry(_other), do: nil
end
