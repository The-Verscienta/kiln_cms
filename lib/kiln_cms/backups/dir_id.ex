defmodule KilnCMS.Backups.DirId do
  @moduledoc """
  Which backup directory this node writes to (#2218).

  A step chain's files (`.work/<stamp>/`, the dump, the media parts) live in one
  `BACKUP_DIR`. On a cluster where each host has its own `BACKUP_DIR`, every
  step after `start` must run on a node that sees the same directory, so each
  directory carries a random id in `<BACKUP_DIR>/.kiln-dir-id`: the `start` step
  records the id of the directory it wrote `state.json` to on the lock when it
  hands over to `dump` (a retried start may run on another node and pick its
  own), and in every later step's args, and a step on a node
  with a different id snoozes until a node with the right one picks it up
  (`KilnCMS.Backups.StepWorker`). Nodes sharing one directory (a shared volume)
  read the same id, so any of them may run any step.

  The file is created by the first in-app backup (`local/1`), or by each node's
  heartbeat when the last-good marker sync is on and the directory already
  holds backups (`ensure_existing/1`, #2789), so the marker sync can route to
  a directory only `scripts/backup.sh` writes to. It is published whole: the
  id is written to a temporary file in the same directory and hard-linked into
  place, so a reader never sees an empty or half-written id, and two nodes
  racing on a shared directory settle on the first link. Cloning a backup
  directory to another host clones its id: delete `.kiln-dir-id` on the copy
  (`rsync --exclude .kiln-dir-id`), or the two directories look like one.
  """
  alias KilnCMS.Backups

  @file_name ".kiln-dir-id"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc "The id file of the backup directory `dir`."
  @spec path(Path.t()) :: Path.t()
  def path(dir \\ Backups.dir()), do: Path.join(dir, @file_name)

  @doc """
  This node's backup-directory id, creating the directory (0700) and the id
  file (0600) when there is none yet. `{:error, reason}` when neither can be
  written, or the file holds something that is not an id.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec local(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def local(dir \\ Backups.dir()) do
    case current(dir) do
      {:ok, id} -> {:ok, id}
      {:error, :enoent} -> create(dir)
      {:error, _} = error -> error
    end
  end

  @doc """
  The id already recorded in `dir`, without creating one: `{:error, :enoent}`
  when there is none. What a step's affinity check reads: a node with no id
  is not the node a chain's files are on.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec current(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def current(dir \\ Backups.dir()) do
    with {:ok, text} <- File.read(path(dir)) do
      id = String.trim(text)
      if Regex.match?(@uuid, id), do: {:ok, id}, else: {:error, :malformed_dir_id}
    end
  end

  @doc """
  The id of `dir`, creating the id file (0600) when there is none yet and
  `dir` already holds backups: it exists and has a `db/` or `media/`
  subdirectory. What each node's heartbeat reports when the marker sync is on
  (#2789). Never creates the directory: the runtime image makes an empty
  `BACKUP_DIR` on every replica, and a mount that failed leaves an empty
  mountpoint; neither is a backup directory to route to. `{:error, :enoent}`
  when there is no id and none was created; a file that holds something that
  is not an id is left as it is (`{:error, :malformed_dir_id}`).
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec ensure_existing(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_existing(dir \\ Backups.dir()) do
    case current(dir) do
      {:error, :enoent} -> if holds_backups?(dir), do: publish(dir), else: {:error, :enoent}
      result -> result
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp holds_backups?(dir) do
    File.dir?(dir) and
      (File.dir?(Path.join(dir, "db")) or File.dir?(Path.join(dir, "media")))
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp create(dir) do
    with :ok <- File.mkdir_p(dir), do: publish(dir)
  end

  # The id goes to a temporary file in `dir` first, synced, and is then
  # hard-linked to its name, which fails with `:eexist` when the name is taken:
  # a reader sees no file or the whole id, never an empty one (an exclusive
  # create of the name itself would show it empty until the write lands). The
  # temporary file is removed whatever happens.
  #
  # A filesystem without hard links gets the exclusive create of the name
  # itself: `link(2)` gives EPERM or ENOTSUP on FAT, ENOSYS on a FUSE mount
  # without link support, EOPNOTSUPP on some CIFS mounts, and other errnos
  # elsewhere, so every link error but `:eexist` falls back. The create still
  # settles a race on one id, with the empty-file window the link avoids,
  # rather than leaving that host without an id and so without in-app backups.
  # An error the create would hit too (`:eacces`, `:erofs`, `:enospc`) comes
  # back from the create. `ln` is `File.ln/2` outside tests.
  @doc false
  # sobelow_skip ["Traversal.FileModule"]
  @spec publish(Path.t(), (Path.t(), Path.t() -> :ok | {:error, term()})) ::
          {:ok, String.t()} | {:error, term()}
  def publish(dir, ln \\ &File.ln/2) do
    id = Ash.UUID.generate()
    tmp = Path.join(dir, "#{@file_name}.#{Ash.UUID.generate()}.tmp")

    try do
      with :ok <- write_exclusive(tmp, id),
           :ok <- link(ln, tmp, path(dir), id) do
        {:ok, id}
      else
        # Another node (or process) published first: theirs is the id.
        {:error, :eexist} -> current(dir)
        {:error, _} = error -> error
      end
    after
      File.rm(tmp)
    end
  end

  defp link(ln, tmp, file, id) do
    case ln.(tmp, file) do
      {:error, reason} when reason != :eexist -> write_exclusive(file, id)
      result -> result
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_exclusive(file, id) do
    with {:ok, io} <- File.open(file, [:write, :exclusive]) do
      try do
        with :ok <- IO.binwrite(io, id <> "\n"),
             :ok <- :file.sync(io),
             do: File.chmod(file, 0o600)
      after
        File.close(io)
      end
    end
  end
end
