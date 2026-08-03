defmodule KilnCMS.Governance.Witness.File do
  @moduledoc """
  Filesystem witness: one JSON file per checkpoint (#666).

      config :kiln_cms, KilnCMS.Governance.Witness, adapter: KilnCMS.Governance.Witness.File
      config :kiln_cms, KilnCMS.Governance.Witness.File, dir: "/var/lib/kiln/governance"

  (`KILN_GOVERNANCE_WITNESS=file`, `KILN_GOVERNANCE_WITNESS_DIR=…`.)

  Files are created **exclusively** — `:exclusive` fails with `:eexist` rather
  than truncating — so a re-run, a replayed Oban job, or a second node cannot
  replace a checkpoint that was already published. That is the one property the
  sink has to have; without it an attacker who can write the directory rewrites
  the record instead of deleting it, which is strictly worse because it looks
  intact.

  A local directory the application can also `unlink` buys less than it appears
  to, so point this at something that outlives the application's own privileges:
  a bind mount the container user cannot delete from, a volume with an
  append-only attribute (`chattr +a` on ext4), or a spool an off-host agent
  drains. Being explicit about that is why this exists alongside the S3 adapter
  rather than as its dev-mode fallback.
  """
  @behaviour KilnCMS.Governance.Witness

  alias KilnCMS.Governance.Witness

  @impl true
  # `key` is built by `Witness.key/2` from an org uuid and an integer, never
  # from request input, and is validated below regardless.
  # sobelow_skip ["Traversal.FileModule"]
  def publish(key, body) do
    with {:ok, path} <- path(key),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.open(path, [:write, :binary, :exclusive]) do
        {:ok, io} -> write(io, path, body)
        {:error, :eexist} -> {:error, :already_published}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # `IO.binwrite/2` signals a write failure by raising, not by returning an
  # error tuple, so the rescue is the error path rather than belt-and-braces:
  # publication runs in a background worker whose contract is to record the
  # failure and let the next run retry, never to crash the checkpoint that was
  # already minted.
  #
  # A failed write REMOVES the file it created. The exclusive open is what
  # reserves the key, so a truncated file left behind would make every retry of
  # that sequence report `:already_published` — which `Checkpoint.publish/2` used
  # to record as success, permanently marking a checkpoint witnessed by bytes
  # that can never match. Removing our own partial write is the only case where
  # this adapter deletes anything, and it is bounded to a file it just created.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(io, path, body) do
    IO.binwrite(io, body)
    {:ok, receipt(path, body)}
  rescue
    error ->
      File.rm(path)
      {:error, error}
  after
    File.close(io)
  end

  defp receipt(path, body) do
    %{
      "path" => path,
      "bytes" => byte_size(body),
      "sha256" => Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    }
  end

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def fetch(key) do
    with {:ok, path} <- path(key) do
      case File.read(path) do
        {:ok, body} -> {:ok, body}
        {:error, :enoent} -> {:error, :not_published}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def list(org_id) do
    with {:ok, dir} <- path(org_id) do
      case File.ls(dir) do
        {:ok, names} ->
          {:ok,
           names |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.map(&"#{org_id}/#{&1}")}

        # An org that has never published has no directory. That is "no keys",
        # not an error — the audit needs to tell it apart from a sink it cannot
        # read, which is a finding.
        {:error, :enoent} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def describe do
    case Keyword.get(Witness.config(__MODULE__), :dir) do
      nil -> "file (unconfigured — set KILN_GOVERNANCE_WITNESS_DIR)"
      dir -> "file (#{dir})"
    end
  end

  # Refuses a key that escapes the configured directory. `Witness.key/2` cannot
  # produce one, and the check is here anyway: this module is also the audit
  # path's reader, and an attacker who can write `chain_checkpoints` chooses the
  # key it fetches. A traversal there turns a read-only audit into an arbitrary
  # file read.
  #
  # The directory must be ABSOLUTE. `Path.expand/1` resolves a relative one
  # against the current working directory, and the two processes that touch this
  # sink deliberately run from different places: the release publishes from its
  # own root, and the audit is documented as running from another host entirely.
  # A relative path therefore publishes to one directory and audits another,
  # whose symptom is every checkpoint reported MISSING — the loudest possible
  # false positive on the one tool that has to be trustworthy.
  defp path(key) do
    case Keyword.get(Witness.config(__MODULE__), :dir) do
      nil ->
        {:error, :witness_dir_not_configured}

      dir ->
        if Path.type(dir) == :absolute do
          resolve(dir, key)
        else
          {:error, :witness_dir_not_absolute}
        end
    end
  end

  defp resolve(dir, key) do
    root = Path.expand(dir)
    candidate = Path.expand(Path.join(root, key))

    if candidate == root or String.starts_with?(candidate, root <> "/") do
      {:ok, candidate}
    else
      {:error, :invalid_witness_key}
    end
  end
end
