defmodule KilnCMS.CMS.Changes.CheckpointCollabRoom do
  @moduledoc """
  Carries an open collab room's converged prose into the publish that is about
  to close it (#1061).

  `Collab.Crdt.Checkpoint` writes a room's text back through `:autosave`, which
  since #1015 carries a row-level `state == :draft` filter. So a publish landing
  while editors are still typing leaves the DocServer holding prose that no
  client autosave captured, and the next checkpoint is refused — the Y.Doc goes
  away with the server and the text is simply gone. The client side compounds
  it: `ContentEditorLive.mark_dirty/1` stops autosaving once the record is not a
  draft, so after the publish nobody is persisting at all while the shared doc
  keeps accepting edits.

  Nothing at the point of *discovery* can fix that — by the time the checkpoint
  is refused the publish has already snapshotted whatever the row held. But at
  the moment of the publish the room is still open and the prose is still
  reachable, so this asks for it and publishes that instead.

  ## Why it rides in the publish's own changeset

  The obvious alternative — flush through `:autosave` first, then publish — is
  not atomic: a publish that succeeded after a flush that failed would still
  lose the text, which is the failure being fixed. Force-changing `:blocks` here
  means the converged prose is what gets published, versioned
  (`RecordPublishedVersion`), indexed (`SetSearchText`) and fired
  (`FireArtifacts`) — one write, or none.

  (An earlier version of this note also claimed a flush would break the
  publish's optimistic lock. That is false: `:publish` carries no
  `optimistic_lock` — only `:update` and `:autosave` do — and flush-then-publish
  works on the happy path. Atomicity is the reason; the lock never was.)

  `:publish` declares `accept []`, deliberately: a publish takes no content
  input *from the caller*. This is not caller input. It is the server reading
  its own authoritative doc, which is why it is a `force_change` rather than an
  argument.

  ## What it does not do

  It never starts a room. `Crdt.converged_blocks/2` looks the server up, so a
  publish for a record nobody is editing — every scheduled publish, every API
  publish, the overwhelming majority — costs one `Registry.lookup` and nothing
  else.

  It never refuses a publish. A collab prototype that is misbehaving must not be
  able to stop content going live; the failure it exists to prevent is bad, and
  refusing the publish would be worse. Anything unexpected leaves the changeset
  untouched, which is exactly the behaviour that shipped before this existed.
  """
  use Ash.Resource.Change

  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Collab.Crdt

  @impl true
  def change(changeset, _opts, _context) do
    # Resolved HERE, at build time, and closed over — never inside the hooks.
    # `type_name_for/1` goes through the dynamic-type registry for a D17 record,
    # which is a `Cachex.fetch` whose miss reads the database, and a cached
    # resolve inside a write transaction is the courier-wants-a-second-connection
    # hazard this codebase has hit before. `Validations.ComplianceClaims` avoids
    # it by the same means.
    kind = ContentTypes.type_name_for(changeset.data)

    changeset
    |> Ash.Changeset.before_action(&merge_converged_prose(&1, kind))
    |> Ash.Changeset.after_transaction(fn _changeset, result -> announce(result, kind) end)
  end

  # After the transaction, so the room is never told about a publish that then
  # rolled back — `after_action` would broadcast before the commit (the trap
  # this codebase has hit before). Best-effort: an editor who misses this still
  # has their prose, because the write above already took it.
  defp announce({:ok, record} = result, kind) do
    if Crdt.enabled?() and not is_nil(kind) do
      KilnCMSWeb.Endpoint.broadcast(Crdt.doc_key(kind, record.id), "published", %{})
    end

    result
  rescue
    # `result`, never a reconstruction of it: returning `changeset.data` here
    # would hand the caller the PRE-publish record as the publish's result.
    error ->
      Logger.warning("Collab publish announcement failed: #{inspect(error)}")
      result
  end

  defp announce(result, _kind), do: result

  defp merge_converged_prose(changeset, kind) do
    with true <- Crdt.enabled?(),
         false <- is_nil(kind),
         %{id: id} = record when not is_nil(id) <- changeset.data,
         {:ok, blocks} <- Crdt.converged_blocks(Crdt.doc_key(kind, id), record) do
      Ash.Changeset.force_change_attribute(changeset, :blocks, blocks)
    else
      _no_room -> changeset
    end
  rescue
    error ->
      # Loud, because the symptom this guards is silent by nature: without the
      # log, a broken checkpoint path looks exactly like "no room was open".
      Logger.warning(
        "Collab checkpoint-on-publish failed, publishing as stored: #{inspect(error)}"
      )

      changeset
  end
end
