defmodule KilnCMS.Backups.PruneStatus do
  @moduledoc """
  What the host's last `scripts/backup.sh prune` said about itself (#3003),
  read from `<BACKUP_DIR>/.kiln-prune-status.json` and kept as a retention
  notice (`KilnCMS.Backups.Notices`), so a cron prune that was skipped, or
  that left something in place, shows on the Backups page and Home instead of
  only in the cron log.

  ## The file

  `backup.sh prune` (and `all`, which prunes) writes it at the end of every
  prune, atomically (a temporary file renamed into place):

      {"version": 1, "at": "2026-11-18T03:17:09Z", "outcome": "skipped",
       "reason": "could not list /var/backups/kiln/db", "warnings": 1}

    * `outcome` is `"ok"`, `"skipped"` (nothing was pruned) or `"partial"`
      (the prune ran but warned: a unit it couldn't read or a file it
      couldn't remove was kept).
    * `reason` is the script's first warning, `null` when `ok`.
    * `warnings` is how many it printed.

  A later version may add fields; this reads the ones above and ignores the
  rest. The script and this module change together (ADR 0042 style:
  `scripts/backup.sh`'s prune section names this module, and
  `test/scripts/backup_script_test.exs` checks the file it writes parses
  here).

  ## The notice

  A `"skipped"` file reports a `:retention` notice with `outcome: :skipped`,
  and a `"partial"` one with `outcome: :stopped`, both under the directory's
  cron scope (`"cron:<dir id>"`, or `"cron"` for a directory without an id,
  see `KilnCMS.Backups.Notices`), dated by the file's `at`. An `"ok"` file
  clears that scope. The app's own prune reports under `"local:<dir id>"`
  and writes no status file, so the two never clear each other's notice: a
  clean in-app pass says nothing about whether cron's prune works, and the
  other way round.

  ## When it is read

  Only by `KilnCMS.Backups.MarkerSyncWorker`, before each sync of its own
  backup directory: off the request path, inside the sync's bounded I/O task
  (#3079), never on a LiveView process. Every read applies the file as it
  is, so reading the same file again changes nothing: the report is an
  upsert of the same row, the clear finds nothing left to clear.

  A file that is missing (a host that never ran this release's
  `backup.sh prune`, or one that stopped and whose file was removed), or one
  older than eight days (cron stopped pruning, which the backup's own
  staleness alarm covers), clears the directory's cron notice: cron no
  longer reports, so its last word must not stand for ever. The old file is
  also said in an info line; a missing one says nothing. A file that can't
  be read, is larger than 4096 bytes, isn't the JSON above, or is dated more
  than five minutes ahead of this node's clock fails closed: it is ignored
  with a warning and leaves any notice as it was.
  """

  alias KilnCMS.Backups
  alias KilnCMS.Backups.Notices

  require Logger

  @file_name ".kiln-prune-status.json"
  @max_bytes 4096
  @max_age_s 8 * 86_400
  @future_slack_s 300
  @outcomes %{"ok" => :ok, "skipped" => :skipped, "partial" => :partial}

  @typedoc "The file, parsed."
  @type t :: %{
          at: DateTime.t(),
          outcome: :ok | :skipped | :partial,
          reason: String.t() | nil,
          warnings: non_neg_integer()
        }

  @doc "The status file's name, at the root of the backup directory."
  @spec file_name() :: String.t()
  def file_name, do: @file_name

  @doc "The status file of the backup directory `dir`."
  @spec path(Path.t()) :: Path.t()
  def path(dir \\ Backups.dir()), do: Path.join(dir, @file_name)

  @doc """
  Read and parse `dir`'s status file: `{:ok, status}`, `:none` when there is
  no file, or `{:error, reason}` for one that can't be read or isn't the
  format above. Age is not judged here (`sync/2` does).
  """
  @spec read(Path.t()) :: {:ok, t()} | :none | {:error, term()}
  def read(dir) do
    case read_bounded(path(dir)) do
      {:ok, text} -> parse(text)
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Read `dir`'s status file and record it as the directory's cron retention
  notice (see the moduledoc). Always `:ok`: a file that can't be used is
  logged and ignored, and a notice write that fails is logged by `Notices`.

  Options: `:now`, a `DateTime` (default: now).
  """
  @spec sync(Path.t(), keyword()) :: :ok
  def sync(dir, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case read(dir) do
      :none ->
        Notices.retention({:cron, dir}, :ok)

      {:ok, status} ->
        apply_status(dir, status, now)

      {:error, reason} ->
        Logger.warning(
          "Ignored #{path(dir)}: #{describe_error(reason)}. The cron prune's outcome " <>
            "isn't shown until backup.sh prune writes it again"
        )
    end
  end

  defp apply_status(dir, %{at: at} = status, now) do
    cond do
      DateTime.diff(at, now) > @future_slack_s ->
        Logger.warning(
          "Ignored #{path(dir)}: it is dated #{DateTime.to_iso8601(at)}, ahead of this " <>
            "node's clock"
        )

      DateTime.diff(now, at) > @max_age_s ->
        Logger.info(
          "Ignored #{path(dir)}: written #{DateTime.to_iso8601(at)}, more than " <>
            "#{div(@max_age_s, 86_400)} days ago; the cron prune's notice is cleared"
        )

        Notices.retention({:cron, dir}, :ok)

      true ->
        Notices.retention({:cron, dir}, result(status), at: at)
    end
  end

  defp result(%{outcome: :ok}), do: :ok
  defp result(%{outcome: :skipped} = status), do: {:skipped, {:cron_prune, reason(status)}}
  defp result(%{outcome: :partial} = status), do: {:stopped, {:cron_prune, reason(status)}, nil}

  defp reason(%{reason: reason, warnings: warnings}) do
    reason = reason || "backup.sh prune gave no reason"

    if warnings > 1,
      do: "#{reason} (and #{warnings - 1} more warning(s) in the cron log)",
      else: reason
  end

  # At most @max_bytes + 1 bytes, so an oversized file is told apart without
  # reading all of it.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_bounded(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, @max_bytes + 1) do
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, reason}
          data when byte_size(data) > @max_bytes -> {:error, :too_large}
          data -> {:ok, data}
        end
      after
        File.close(io)
      end
    end
  end

  defp parse(text) do
    with {:ok, %{} = map} <- decode(text),
         {:ok, _version} <- version(map["version"]),
         {:ok, at} <- at(map["at"]),
         {:ok, outcome} <- Map.fetch(@outcomes, map["outcome"]) |> or_error(:outcome),
         {:ok, reason} <- reason_field(map["reason"]),
         {:ok, warnings} <- warnings(map["warnings"]) do
      {:ok, %{at: at, outcome: outcome, reason: reason, warnings: warnings}}
    else
      {:ok, _not_an_object} -> {:error, :not_an_object}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, :not_json}
    end
  end

  defp version(v) when is_integer(v) and v >= 1, do: {:ok, v}
  defp version(_v), do: {:error, :version}

  defp at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _} -> {:error, :at}
    end
  end

  defp at(_text), do: {:error, :at}

  defp reason_field(nil), do: {:ok, nil}
  defp reason_field(text) when is_binary(text), do: {:ok, text}
  defp reason_field(_other), do: {:error, :reason}

  defp warnings(nil), do: {:ok, 0}
  defp warnings(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp warnings(_n), do: {:error, :warnings}

  defp or_error({:ok, value}, _field), do: {:ok, value}
  defp or_error(:error, field), do: {:error, field}

  defp describe_error(:too_large), do: "it is larger than #{@max_bytes} bytes"
  defp describe_error(:not_json), do: "it is not JSON"
  defp describe_error(:not_an_object), do: "it is not a JSON object"

  defp describe_error(field) when field in [:version, :at, :outcome, :reason, :warnings],
    do: "its #{field} is missing or malformed"

  defp describe_error(reason), do: "it can't be read (#{inspect(reason)})"
end
