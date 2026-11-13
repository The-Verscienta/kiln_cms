defmodule KilnCMS.Backups.Manifest do
  @moduledoc """
  The one file that says what the last backup was (#484).

  A JSON document at `<BACKUP_DIR>/manifest.json`, written by **both** backup
  paths — `scripts/backup.sh` and `KilnCMS.Backups.Worker` — and read by the
  console. It exists because the console has to be able to report on a backup
  it did not run: the canonical path is still cron calling the shell script,
  and a status panel that only knew about app-triggered backups would show
  "never" on exactly the deployments that are backing up correctly.

  Deriving the same facts by scanning the directory was the alternative, and
  it can't answer the question that matters. A `.dump` on disk proves a file
  exists, not that `pg_restore --list` accepted it — and an unverified dump is
  the one thing a backup system must never count. Verification is a fact only
  the writer knows, so the writer records it.

  ## Shape

  ```json
  {
    "version": 1,
    "started_at": "2026-08-05T03:17:00Z",
    "finished_at": "2026-08-05T03:18:42Z",
    "trigger": "cron",
    "ok": true,
    "artifacts": [
      {"kind": "db", "path": "db/kiln-db-20260805-031700.dump",
       "bytes": 48317216, "verified": true}
    ],
    "offsite": "r2:kiln-backups",
    "keep_days": 14,
    "error": null
  }
  ```

  Paths are **relative to the backup directory**, so a manifest stays true
  when the directory is moved or read from a different mount.

  ## Checksums and parts (#2218)

  An entry may also carry `"sha256"` (hex of that file's bytes), and a media
  entry written in parts carries `"part"` (1-based) and `"parts_total"`. Each
  part is its own flat entry, in part order:

  ```json
  {"kind": "media", "path": "media/kiln-media-20260805-031700.part01.tar.gz",
   "bytes": 419430400, "verified": true, "sha256": "3b1f…",
   "part": 1, "parts_total": 2}
  ```

  ## Components (#2219)

  A backup may cover only the database or only the media. Kiln writes what it
  covered as `"components"` (`["db"]`, `["media"]` or `["db", "media"]`); a
  manifest without the key (`scripts/backup.sh`, or Kiln before #2219) covers
  the kinds of its artifacts (`components/1`).

  ## Stamp

  The run's stamp (`"20260805-031700"`, the name its files and its Run carry)
  is written as `"stamp"`. It is not derivable from `started_at`: Kiln takes
  the stamp when the chain is leased and stamps the start a moment later, and
  steps the stamp past one already in use, so the two can name different
  seconds. A reader keys a run by `"stamp"` when it is there and by
  `started_at` otherwise (a manifest written before the key existed). A stamp
  that is not a real instant reads as absent.

  The keys are additive and the version stays 1: a manifest without them reads
  exactly as before (the keys are absent from the parsed entry, not `nil`), and
  a reader that doesn't know them ignores them. `total_bytes/1` and
  `verified?/1` count every part.

  ## Reading is total

  `read/1` never raises. A missing file, a truncated write, a manifest from a
  future version, a hand-edited one — all return `nil` or a struct with the
  fields that parsed. The console's job is to say "no backup has ever run
  here", and it can't do that if reading throws.
  """

  @type artifact :: %{
          required(:kind) => String.t(),
          required(:path) => String.t(),
          required(:bytes) => non_neg_integer(),
          required(:verified) => boolean(),
          optional(:sha256) => String.t(),
          optional(:part) => pos_integer(),
          optional(:parts_total) => pos_integer()
        }

  @type t :: %__MODULE__{
          version: pos_integer(),
          stamp: String.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          trigger: String.t(),
          ok: boolean(),
          components: [String.t()] | nil,
          artifacts: [artifact()],
          offsite: String.t() | nil,
          keep_days: pos_integer() | nil,
          error: String.t() | nil
        }

  defstruct version: 1,
            stamp: nil,
            started_at: nil,
            finished_at: nil,
            trigger: "unknown",
            ok: false,
            components: nil,
            artifacts: [],
            offsite: nil,
            keep_days: nil,
            error: nil

  @filename "manifest.json"

  @doc "The manifest's path inside a backup directory."
  @spec path(Path.t()) :: Path.t()
  def path(dir), do: Path.join(dir, @filename)

  @doc """
  Read the manifest from `dir`, or `nil` when there isn't a usable one.

  Total by design — see the moduledoc.
  """
  # `dir` comes from application config, never from a request — the traversal
  # warning is the same false positive as elsewhere in this codebase.
  # sobelow_skip ["Traversal.FileModule"]
  @spec read(Path.t()) :: t() | nil
  def read(dir) when is_binary(dir) do
    with {:ok, contents} <- File.read(path(dir)),
         {:ok, %{} = decoded} <- Jason.decode(contents) do
      from_map(decoded)
    else
      _ -> nil
    end
  end

  def read(_dir), do: nil

  @doc """
  Write `manifest` into `dir`, atomically.

  Written to a temp name and renamed, for the same reason `backup.sh` renames
  its dumps: a reader that catches a half-written manifest would report a
  backup that didn't happen, and `rename` within a directory is atomic on
  every filesystem this runs on.

  Best-effort — a failed manifest write must never fail the backup it
  describes. Losing the record of a good backup is bad; deleting a good backup
  because its record couldn't be written is worse.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec write(Path.t(), t()) :: :ok | {:error, term()}
  def write(dir, %__MODULE__{} = manifest) when is_binary(dir) do
    target = path(dir)
    tmp = target <> ".partial"

    with :ok <- File.mkdir_p(dir),
         {:ok, json} <- Jason.encode(to_map(manifest), pretty: true),
         :ok <- File.write(tmp, json <> "\n"),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      # Every step above returns `:ok` or `{:error, _}`, so there is no third
      # shape to catch — a defensive clause here would be unreachable.
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  @doc "Total bytes across every artifact — what the panel shows as the backup's size."
  @spec total_bytes(t() | nil) :: non_neg_integer()
  def total_bytes(nil), do: 0

  def total_bytes(%__MODULE__{artifacts: artifacts}),
    do: Enum.sum(Enum.map(artifacts, & &1.bytes))

  @doc """
  Whether every artifact in the manifest verified.

  An empty artifact list is **not** verified: a backup that produced nothing
  is a failed backup, and `Enum.all?/2` over an empty list would call it a
  success.
  """
  @spec verified?(t() | nil) :: boolean()
  def verified?(nil), do: false
  def verified?(%__MODULE__{artifacts: []}), do: false
  def verified?(%__MODULE__{artifacts: artifacts}), do: Enum.all?(artifacts, & &1.verified)

  @doc """
  What the backup covered: its `"components"`, or, in a manifest without the
  key, the kinds of its artifacts. `[]` for neither.
  """
  @spec components(t() | nil) :: [String.t()]
  def components(nil), do: []
  def components(%__MODULE__{components: components}) when is_list(components), do: components

  def components(%__MODULE__{artifacts: artifacts}),
    do: artifacts |> Enum.map(& &1.kind) |> Enum.uniq()

  defp to_map(%__MODULE__{} = m) do
    %{
      "version" => m.version,
      "started_at" => iso(m.started_at),
      "finished_at" => iso(m.finished_at),
      "trigger" => m.trigger,
      "ok" => m.ok,
      "artifacts" =>
        Enum.map(m.artifacts, fn a ->
          %{"kind" => a.kind, "path" => a.path, "bytes" => a.bytes, "verified" => a.verified}
          |> put_present("sha256", Map.get(a, :sha256))
          |> put_present("part", Map.get(a, :part))
          |> put_present("parts_total", Map.get(a, :parts_total))
        end),
      "offsite" => m.offsite,
      "keep_days" => m.keep_days,
      "error" => m.error
    }
    |> put_present("components", m.components)
    |> put_present("stamp", m.stamp)
  end

  defp from_map(map) do
    %__MODULE__{
      version: integer(map["version"]) || 1,
      stamp: stamp(map["stamp"]),
      started_at: datetime(map["started_at"]),
      finished_at: datetime(map["finished_at"]),
      trigger: string(map["trigger"]) || "unknown",
      ok: map["ok"] == true,
      components: components_list(map["components"]),
      artifacts: artifacts(map["artifacts"]),
      offsite: string(map["offsite"]),
      keep_days: positive(map["keep_days"]),
      error: string(map["error"])
    }
  end

  defp artifacts(list) when is_list(list) do
    for %{} = entry <- list,
        kind = string(entry["kind"]),
        path = string(entry["path"]),
        kind && path do
      %{
        kind: kind,
        path: path,
        bytes: integer(entry["bytes"]) || 0,
        verified: entry["verified"] == true
      }
      |> put_present(:sha256, sha256(entry["sha256"]))
      |> put_present(:part, positive(entry["part"]))
      |> put_present(:parts_total, positive(entry["parts_total"]))
    end
  end

  defp artifacts(_other), do: []

  # Known names only, each once; anything else reads as absent.
  defp components_list(list) when is_list(list) do
    case for(name <- ["db", "media"], name in list, do: name) do
      [] -> nil
      names -> names
    end
  end

  defp components_list(_other), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp stamp(value) when is_binary(value) do
    case KilnCMS.Backups.Artifact.parse_stamp(value) do
      {:ok, _at} -> value
      :error -> nil
    end
  end

  defp stamp(_value), do: nil

  defp sha256(value) when is_binary(value) do
    if value =~ ~r/\A[0-9a-fA-F]{64}\z/, do: String.downcase(value), else: nil
  end

  defp sha256(_value), do: nil

  defp positive(value) when is_integer(value) and value >= 1, do: value
  defp positive(_value), do: nil

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp datetime(_value), do: nil

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil
end
