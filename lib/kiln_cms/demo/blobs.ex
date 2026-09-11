defmodule KilnCMS.Demo.Blobs do
  @moduledoc """
  Media blobs across a demo reset. See `docs/demo-mode.md`.

  A database restore rewinds the `media_items` rows but not the files they
  point at, which live in `KilnCMS.Storage` — a directory or a bucket the
  restore never sees. Two things go wrong without this module, in opposite
  directions:

    * **Uploads leak.** Every file a visitor uploads outlives the row that
      referenced it. On a public demo that is unbounded disk, written by
      strangers.
    * **The golden media breaks.** Worse, and easier to trigger: a visitor who
      purges a golden image from the trash, or rotates one (which regenerates
      its variants and deletes the old ones), deletes files the golden
      snapshot still references. The restore brings the rows back; the files
      stay gone; every reset from then on serves broken images.

  ## Deletes are deferred, and decided at the reset

  In demo mode `KilnCMS.Storage.delete/1` and `delete_private/1` do not delete.
  They append the key to a log beside the golden snapshot (`defer/1`) and
  return `:ok`. Nothing a visitor does can remove a file.

  The reset then deletes, with full knowledge of what the golden state needs:

      candidates = keys the pre-reset database referenced
                 ∪ keys deferred during the session
      deleted    = candidates − keys the restored (golden) database references

  So a file is removed only if the demo created it *and* the golden state does
  not use it. The subtraction is the safety property: a key the golden snapshot
  references is never deleted, whatever happened during the session.

  Only keys Kiln itself recorded are ever candidates — the storage is never
  *listed* — so a demo accidentally sharing a bucket with another deployment
  deletes nothing that deployment wrote. What that leaves behind is an upload
  that failed before any row or deferral recorded it, the same residue a
  production deployment has.
  """

  require Logger

  alias KilnCMS.Repo
  alias KilnCMS.Storage

  @log "deferred-deletes"

  # Every storage key the application writes lives on `media_items`: the
  # original in `storage_key`, each derived file (responsive variants, the A/V
  # poster) as `variants.<label>.key`. Raw SQL rather than an Ash read so
  # soft-deleted (archived) rows count — their files are still referenced — and
  # so no policy or tenant scoping can hide a row.
  #
  # The CASE keeps `jsonb_each` off a non-object `variants`, which it raises on.
  @keys_sql """
  SELECT storage_key FROM media_items WHERE storage_key IS NOT NULL
  UNION
  SELECT v.value ->> 'key'
  FROM media_items m
  CROSS JOIN LATERAL jsonb_each(
    CASE WHEN jsonb_typeof(m.variants) = 'object' THEN m.variants ELSE '{}'::jsonb END
  ) AS v
  WHERE v.value ->> 'key' IS NOT NULL
  """

  @doc """
  Every storage key the connected database references.

  `{:error, _}` rather than an empty set on failure: the caller subtracts the
  *golden* set from the candidates, and an empty golden set would make every
  file a candidate.
  """
  @spec referenced_keys() :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def referenced_keys do
    case Repo.query(@keys_sql, []) do
      {:ok, %{rows: rows}} -> {:ok, MapSet.new(rows, fn [key] -> key end)}
      {:error, error} -> {:error, error}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Records `key` for deletion at the next reset instead of deleting it. Always
  `:ok` — see the moduledoc for why nothing is deleted now.

  A failure to record is logged and swallowed: the cost is one leaked file,
  and failing the caller would fail an editor's delete over bookkeeping.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec defer(String.t()) :: :ok
  def defer(key) when is_binary(key) do
    if String.contains?(key, "\n") do
      Logger.warning("Demo mode: not recording a storage key containing a newline")
    else
      path = log_path()

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, key <> "\n", [:append]) do
        :ok
      else
        {:error, reason} ->
          Logger.warning("Demo mode: couldn't record a deferred delete (#{inspect(reason)})")
      end
    end

    :ok
  end

  @doc """
  Deletes the demo's own files after a restore. See the moduledoc for the set
  arithmetic.

  The deferred log is moved aside before it is read, so a delete deferred while
  this runs lands in a fresh log for the next reset rather than being lost.

  Returns `%{deleted: n, failed: n}`; a file that could not be deleted is
  logged and counted, never raised — the restore it follows has already
  committed.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec reap(MapSet.t(String.t()), MapSet.t(String.t())) :: %{
          deleted: non_neg_integer(),
          failed: non_neg_integer()
        }
  def reap(dirty_keys, golden_keys) do
    candidates =
      dirty_keys
      |> MapSet.union(take_deferred())
      |> MapSet.difference(golden_keys)

    Enum.reduce(candidates, %{deleted: 0, failed: 0}, fn key, acc ->
      if delete_everywhere(key) == :ok,
        do: %{acc | deleted: acc.deleted + 1},
        else: %{acc | failed: acc.failed + 1}
    end)
  end

  @doc "Where deferred deletes are logged — beside the golden snapshot."
  @spec log_path() :: Path.t()
  def log_path, do: Path.join(KilnCMS.Demo.dir(), @log)

  # sobelow_skip ["Traversal.FileModule"]
  defp take_deferred do
    path = log_path()
    taken = path <> ".reaping"

    case File.rename(path, taken) do
      :ok ->
        keys =
          case File.read(taken) do
            {:ok, body} -> body |> String.split("\n", trim: true) |> MapSet.new()
            {:error, _} -> MapSet.new()
          end

        File.rm(taken)
        keys

      {:error, _nothing_deferred} ->
        MapSet.new()
    end
  end

  # The adapter directly: `Storage.delete/1` is the deferring wrapper this
  # module exists to replace. Public and private both, because a key doesn't
  # record which side it was written to (a quarantined A/V upload is private
  # until promoted), and deleting an absent object is `:ok` on both adapters.
  defp delete_everywhere(key) do
    adapter = Storage.adapter()

    results =
      if adapter.private_available?(),
        do: [adapter.delete(key), adapter.delete_private(key)],
        else: [adapter.delete(key)]

    case Enum.reject(results, &(&1 == :ok)) do
      [] ->
        :ok

      errors ->
        Logger.warning("Demo reset couldn't delete #{key}: #{inspect(errors)}")
        :error
    end
  end
end
