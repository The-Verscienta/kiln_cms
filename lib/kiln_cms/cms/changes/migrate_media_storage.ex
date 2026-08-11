defmodule KilnCMS.CMS.Changes.MigrateMediaStorage do
  @moduledoc """
  Relocates a `MediaItem`'s blob between public and private storage (#481)
  when `audience` changes to or from `:public`.

  Only runs when `audience` is actually changing — an unrelated metadata edit
  (alt text, caption) never touches storage. A transition between two
  *gated* audiences (e.g. `:member` -> `:staff`) needs no relocation at
  all — the blob is already sitting in private storage; only the `audience`
  column changes.

  Two rules enforced here, not in a separate validation, because both need
  to know the transition this change is about to perform:

    * **going public -> gated requires private storage to actually be
      configured** (`KilnCMS.Storage.private_available?/0`) — refused
      outright rather than silently leaving the blob in public storage while
      the row claims to be gated (see `KilnCMS.Storage.S3`'s moduledoc on why
      a public bucket can't fake this);
    * **an image may not be gated** — an image keeps its responsive-variant
      pipeline, which assumes public storage throughout
      (`KilnCMS.Media.VariantWorker` re-fetches originals by public key).
      Documents (#481) and A/V (#494) may both be gated; a members-only video
      is exactly as reasonable as a members-only PDF.

  ## Gating discards derived public blobs

  Video items carry one derived artifact in `variants`: a poster frame
  (`KilnCMS.Media.AVWorker`), written to **public** storage because a public
  video's poster is a plain `<img src>`. A still from a members-only video is
  not something that should stay world-readable once the video isn't, so
  gating deletes those blobs and clears the map rather than relocating them —
  a poster has no reader that could fetch it privately (`<img>` sends no
  Range, needs no counter, and would need a whole second gated route to serve
  from). Un-gating re-derives it (#821) — see `requeue_poster_if_ungated/2`
  below. An editor can still pick a poster by hand on the `video` block, and
  that choice always wins: it lives on the block, not on this row.

  ## Copy-then-delete, not move

  The blob is copied to its new location and `storage_key`/`url` updated on
  the changeset **before** the database commits (`before_action`); the old
  blob is only deleted **after the transaction actually commits**
  (`after_transaction`, not `after_action` — `after_action` still runs
  *inside* the transaction, before commit, so deleting there could drop the
  old blob and then have the surrounding write roll back for an unrelated
  reason, orphaning the row on a since-deleted key). If the transaction
  rolls back, the copy is simply orphaned (cheap, and nothing referenced it
  yet) rather than the row ending up pointing at a key that was already
  deleted. Ash re-runs `before_action` on retry, so a transient copy failure
  never leaves the record half-migrated.
  """
  use Ash.Resource.Change

  alias KilnCMS.Storage

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :audience) do
      changeset
      |> Ash.Changeset.before_action(&migrate/1)
      |> Ash.Changeset.after_transaction(&cleanup_old_blob/2)
      |> Ash.Changeset.after_transaction(&requeue_poster_if_ungated/2)
    else
      changeset
    end
  end

  # Gating a video deletes its poster — row and blob — because a poster renders
  # as a plain `<img>` from PUBLIC storage, and a still of a members-only video
  # must not stay world-readable (`AVWorker.revoke_poster_if_gated/2`).
  #
  # Nothing brought it back on the way out, so a video that was gated and then
  # made public again had no poster for the rest of its life and opened on a
  # black frame (#821). Re-derive it.
  #
  # `after_transaction`, like the blob cleanup above: enqueuing from
  # `after_action` would put a job on the queue that a rolled-back transaction
  # never justified, and the worker would then find the item still gated.
  defp requeue_poster_if_ungated(_changeset, {:ok, record}) do
    if ungated_playable?(record) and not generated_poster?(record) do
      KilnCMS.Media.Ingest.enqueue_processing(record)
    end

    {:ok, record}
  end

  defp requeue_poster_if_ungated(_changeset, other), do: other

  # Video, not `playable?/1`. Audio is playable but `AVWorker.put_poster/4`
  # only writes a poster for video, so an audio item can never satisfy the
  # skip below — every un-gate would stream the whole blob out of storage to
  # re-probe a duration it already has and write nothing. A job that cannot
  # produce the thing it is enqueued to produce should not be enqueued.
  #
  # Deliberately NOT also gated on `AVProcessor.available?()`. That asks
  # whether ffmpeg is on *this* node, and this runs in the web process while
  # the job runs wherever the `:media` queue lives — a deployment that keeps
  # ffmpeg on the worker image and off the web image (a normal split, since it
  # is an optional dependency) would silently never re-derive, with no log
  # line, because the guard's whole job is to enqueue nothing. The worker
  # already tolerates a missing binary; that is where the question belongs.
  defp ungated_playable?(%{audience: :public, content_type: type}),
    do: KilnCMS.MediaKind.of(type) == :video

  defp ungated_playable?(_record), do: false

  # Only skips work already done. This deliberately does NOT try to detect a
  # hand-picked poster, because it cannot and does not need to: a poster an
  # editor chose lives on the BLOCK (`poster_media_id`), `Blocks.Video`'s
  # `poster_src/1` prefers it over anything else, and it never reads the
  # library item's `variants` at all. So re-deriving here cannot replace an
  # editor's choice — the two are different fields and the block's wins.
  defp generated_poster?(%{variants: variants}) when is_map(variants),
    do: Map.has_key?(variants, KilnCMS.AVProcessor.poster_label())

  defp generated_poster?(_record), do: false

  defp migrate(changeset) do
    from = changeset.data.audience
    to = Ash.Changeset.get_attribute(changeset, :audience)

    case gate_check(changeset, from, to) do
      :ok -> relocate_for_transition(changeset, from, to)
      {:error, message} -> gate_error(changeset, message)
    end
  end

  # Un-gating (-> :public) is always allowed — only the *gating* direction
  # needs to prove it's safe.
  defp gate_check(_changeset, _from, :public), do: :ok

  defp gate_check(changeset, from, _to) do
    cond do
      not gateable?(changeset.data.content_type) ->
        {:error, "an image may not be gated to a non-public audience"}

      from == :public and not Storage.private_available?() ->
        {:error,
         "gating requires private storage to be configured — see KilnCMS.Storage.S3's " <>
           "moduledoc for the :private_bucket setting"}

      true ->
        :ok
    end
  end

  defp relocate_for_transition(changeset, from, to) do
    cond do
      from == to ->
        changeset

      from == :public ->
        # public -> gated: no public URL to hand out once it's gated, and no
        # public poster frame either (see the moduledoc).
        changeset
        |> Ash.Changeset.force_change_attribute(:variants, %{})
        |> relocate(false, &Storage.store_private/2, nil)

      to == :public ->
        # gated -> public: restore the ordinary public URL.
        relocate(changeset, true, &Storage.store/2, &Storage.url/1)

      true ->
        # gated -> a different gated audience: already in private storage.
        changeset
    end
  end

  defp gate_error(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :audience, message: message)

  # Images keep the public responsive-variant pipeline (VariantWorker
  # re-fetches originals from public storage) — gating is document-only.
  defp gateable?(content_type), do: is_binary(content_type) and not image?(content_type)
  defp image?(content_type), do: String.starts_with?(content_type, "image/")

  # `old_key`/generated temp path are server-built, never user input — the
  # traversal warning is a false positive (same reasoning as ImageProcessor's
  # temp-file writes).
  # sobelow_skip ["Traversal.FileModule"]
  defp relocate(changeset, private_source?, store, url_fn) do
    old_key = changeset.data.storage_key
    tmp = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-media-migrate")

    try do
      # `copy_to_file/3` rather than a `fetch` + `File.write`: since #494 a
      # media item can be a 500 MB video, and gating one is an ordinary editor
      # action on the request path — reading the blob whole would put that
      # much on the LiveView process's heap.
      with :ok <- Storage.copy_to_file(old_key, tmp, private?: private_source?),
           new_key = Storage.generate_key(changeset.data.filename || old_key),
           {:ok, ^new_key} <- store.(new_key, tmp) do
        changeset
        |> Ash.Changeset.force_change_attribute(:storage_key, new_key)
        |> Ash.Changeset.force_change_attribute(:url, url_fn && url_fn.(new_key))
      else
        {:error, reason} -> gate_error(changeset, "couldn't relocate storage: #{inspect(reason)}")
      end
    after
      File.rm(tmp)
    end
  end

  # `after_transaction`, not `after_action` — this delete is irreversible
  # external state, and must only happen once the DB write it depends on has
  # actually committed (see the moduledoc). A failed/rolled-back result
  # passes straight through: nothing to clean up if the audience change
  # itself never landed.
  defp cleanup_old_blob(changeset, {:ok, record} = result) do
    old_key = changeset.data.storage_key

    # Guard on the KEY actually having changed, not just `audience` — a
    # gated-to-differently-gated transition changes `audience` but never
    # relocates the blob, so `old_key == record.storage_key` there, and
    # "cleaning up" would delete the still-live blob out from under the row.
    if old_key != record.storage_key do
      # The blob's OLD location is public exactly when its NEW audience is
      # gated (it came FROM public); otherwise it came from private storage.
      if record.audience == :public do
        Storage.delete_private(old_key)
      else
        Storage.delete(old_key)
        # The row's `variants` were cleared on the way in (#494); the blobs
        # they named are public objects that outlive the map unless something
        # deletes them, and this is the same post-commit point the original
        # is deleted at.
        delete_variant_blobs(changeset.data.variants)
      end
    end

    result
  end

  defp cleanup_old_blob(_changeset, result), do: result

  # Tolerant of a malformed/absent map: `variants` is a plain `:map`
  # attribute, so a hand-edited row could hold anything, and a cleanup pass
  # is the wrong place to raise.
  defp delete_variant_blobs(variants) when is_map(variants) do
    for {_label, %{"key" => key}} <- variants, is_binary(key), do: Storage.delete(key)
    :ok
  end

  defp delete_variant_blobs(_variants), do: :ok
end
