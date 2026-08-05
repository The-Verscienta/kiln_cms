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

  ## Reading is total

  `read/1` never raises. A missing file, a truncated write, a manifest from a
  future version, a hand-edited one — all return `nil` or a struct with the
  fields that parsed. The console's job is to say "no backup has ever run
  here", and it can't do that if reading throws.
  """

  @type artifact :: %{
          kind: String.t(),
          path: String.t(),
          bytes: non_neg_integer(),
          verified: boolean()
        }

  @type t :: %__MODULE__{
          version: pos_integer(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          trigger: String.t(),
          ok: boolean(),
          artifacts: [artifact()],
          offsite: String.t() | nil,
          keep_days: pos_integer() | nil,
          error: String.t() | nil
        }

  defstruct version: 1,
            started_at: nil,
            finished_at: nil,
            trigger: "unknown",
            ok: false,
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
        end),
      "offsite" => m.offsite,
      "keep_days" => m.keep_days,
      "error" => m.error
    }
  end

  defp from_map(map) do
    %__MODULE__{
      version: integer(map["version"]) || 1,
      started_at: datetime(map["started_at"]),
      finished_at: datetime(map["finished_at"]),
      trigger: string(map["trigger"]) || "unknown",
      ok: map["ok"] == true,
      artifacts: artifacts(map["artifacts"]),
      offsite: string(map["offsite"]),
      keep_days: integer(map["keep_days"]),
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
    end
  end

  defp artifacts(_other), do: []

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
