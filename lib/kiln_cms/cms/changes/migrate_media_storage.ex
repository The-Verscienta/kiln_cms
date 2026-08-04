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
    * **only a document may be gated, not an image** — v1's audience gate is
      scoped to the document library the issue asked for; an image keeps its
      responsive-variant pipeline, which assumes public storage throughout
      (`KilnCMS.Media.VariantWorker` re-fetches originals by public key).

  ## Copy-then-delete, not move

  The blob is copied to its new location and `storage_key`/`url` updated on
  the changeset **before** the database commits (`before_action`); the old
  blob is only deleted **after** the commit succeeds (`after_action`). If the
  transaction rolls back for any unrelated reason, the copy is simply
  orphaned (cheap, and nothing referenced it yet) rather than the row ending
  up pointing at a key that was already deleted. Ash re-runs `before_action`
  on retry, so a transient copy failure never leaves the record half-migrated.
  """
  use Ash.Resource.Change

  alias KilnCMS.Storage

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :audience) do
      changeset
      |> Ash.Changeset.before_action(&migrate/1)
      |> Ash.Changeset.after_action(&cleanup_old_blob/2)
    else
      changeset
    end
  end

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
        {:error, "only documents may be gated to a non-public audience, not images"}

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
        # public -> gated: no public URL to hand out once it's gated.
        relocate(changeset, &Storage.fetch/1, &Storage.store_private/2, nil)

      to == :public ->
        # gated -> public: restore the ordinary public URL.
        relocate(changeset, &Storage.fetch_private/1, &Storage.store/2, &Storage.url/1)

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
  defp relocate(changeset, fetch, store, url_fn) do
    old_key = changeset.data.storage_key

    with {:ok, bytes} <- fetch.(old_key),
         tmp = Path.join(System.tmp_dir!(), "#{Ecto.UUID.generate()}-media-migrate"),
         :ok <- File.write(tmp, bytes),
         new_key = Storage.generate_key(changeset.data.filename || old_key),
         {:ok, ^new_key} <- store.(new_key, tmp) do
      File.rm(tmp)

      changeset
      |> Ash.Changeset.force_change_attribute(:storage_key, new_key)
      |> Ash.Changeset.force_change_attribute(:url, url_fn && url_fn.(new_key))
    else
      {:error, reason} -> gate_error(changeset, "couldn't relocate storage: #{inspect(reason)}")
    end
  end

  defp cleanup_old_blob(changeset, record) do
    old_key = changeset.data.storage_key

    # Guard on the KEY actually having changed, not just `audience` — a
    # gated-to-differently-gated transition changes `audience` but never
    # relocates the blob, so `old_key == record.storage_key` there, and
    # "cleaning up" would delete the still-live blob out from under the row.
    if old_key != record.storage_key do
      # The blob's OLD location is public exactly when its NEW audience is
      # gated (it came FROM public); otherwise it came from private storage.
      if record.audience == :public,
        do: Storage.delete_private(old_key),
        else: Storage.delete(old_key)
    end

    {:ok, record}
  end
end
