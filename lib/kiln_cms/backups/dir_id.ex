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

  The file is created on first use with an exclusive create, so two nodes
  racing on a shared directory settle on one id. Cloning a backup directory to
  another host clones its id: delete `.kiln-dir-id` on the copy.
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

  # sobelow_skip ["Traversal.FileModule"]
  defp create(dir) do
    id = Ash.UUID.generate()

    with :ok <- File.mkdir_p(dir),
         :ok <- write_exclusive(path(dir), id) do
      {:ok, id}
    else
      # Another node (or process) created it first: theirs is the id.
      {:error, :eexist} -> current(dir)
      {:error, _} = error -> error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_exclusive(file, id) do
    with {:ok, io} <- File.open(file, [:write, :exclusive]) do
      try do
        with :ok <- IO.binwrite(io, id <> "\n"), do: File.chmod(file, 0o600)
      after
        File.close(io)
      end
    end
  end
end
