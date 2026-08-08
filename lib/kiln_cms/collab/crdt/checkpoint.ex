defmodule KilnCMS.Collab.Crdt.Checkpoint do
  @moduledoc """
  Writes a collab doc's materialized rich text back into the content record —
  the server-side persistence net for the case client autosave can't cover:
  every editor crashed or disconnected before their debounce fired.

  Runs from the DocServer when the last client detaches (and on server
  shutdown), never while editors are present — the elected client persister
  owns saving then, so the two writers can't race the optimistic lock. Only
  drafts are written (mirroring client autosave), through the same `:autosave`
  action (coalesced PaperTrail versions). Rich-text blocks whose fragment has
  content get their `body` replaced by `Materializer.fragment_body/2`;
  everything else round-trips untouched, and a no-change checkpoint skips the
  write entirely.

  ## Two ways the write can be refused, and only one of them is fine

  A `StaleRecord` used to mean exactly one thing: an editor's save landed first,
  with the same converged content, so there is nothing to do. Since #1015
  `:autosave` also carries a row-level `state == :draft` filter, so a publish
  landing between this module's read and its write refuses it too — and that
  case is **not** fine. The Y.Doc goes away with the terminating DocServer, so
  prose no client autosave captured is simply lost.

  Nothing here can prevent that (the publish already snapshotted whatever the
  record held), but it must not be reported as a successful no-op. `save/2`
  re-reads the row to tell the two apart and warns loudly for the second.
  """
  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Collab.Crdt.Materializer

  @doc """
  Materialize `doc`'s fragments into the record behind `doc_key`. Best-effort.

  `org_id` is the tenant the channel authorized the document under (#655),
  carried down from the `DocServer`. It used to be `default_org_id/0`
  unconditionally — right for a single-org install and wrong for every other
  one, where a checkpoint either found no record or wrote under the wrong site.
  """
  @spec write_back(String.t(), Yex.Doc.t(), Ash.UUID.t()) :: :ok
  def write_back("collab:" <> rest, doc, tenant) do
    with [kind, id] <- String.split(rest, ":", parts: 2),
         ct when not is_nil(ct) <- ContentTypes.get(kind, tenant),
         {:ok, %{state: :draft} = record} <-
           ContentTypes.get_record(ct, id, authorize?: false, tenant: tenant) do
      current = Enum.map(record.blocks, &TypedBlocks.input_map/1)
      materialized = Enum.map(record.blocks, &materialize_block(&1, doc))

      if materialized == current do
        :ok
      else
        save(record, materialized)
      end
    else
      # Unknown topic shape/type, record gone, or not a draft — nothing to do.
      _skip -> :ok
    end
  end

  def write_back(_other_key, _doc, _tenant), do: :ok

  defp materialize_block(%Ash.Union{type: :rich_text} = block, doc) do
    input = TypedBlocks.input_map(block)

    case input["id"] && Materializer.fragment_body(doc, "block-#{input["id"]}") do
      # No id or an empty/absent fragment (never collaboratively edited):
      # keep the stored prose.
      nil ->
        input

      # `body`, not `legacy_html`. Portable Text is authoritative, so the cast
      # nulls `legacy_html` whenever a body is present — a checkpoint writing
      # HTML had it thrown away on the way in and the stale body kept, which
      # made this whole path inert for any block the editor had ever saved.
      # `legacy_html` is left alone here and the cast clears it, converting a
      # never-migrated legacy block to PT on its first collaborative save.
      body ->
        Map.put(input, "body", body)
    end
  end

  defp materialize_block(block, _doc), do: TypedBlocks.input_map(block)

  defp save(record, blocks_input) do
    record
    |> Ash.Changeset.for_update(:autosave, %{blocks: blocks_input},
      authorize?: false,
      tenant: record.org_id
    )
    |> Ash.update()
    |> case do
      {:ok, _saved} ->
        :ok

      {:error, error} ->
        skipped(record, error)
        :ok
    end
  end

  # A refused write is never allowed to crash the DocServer, but it is worth
  # saying WHICH refusal it was — the two have opposite meanings and used to
  # share one `info` line claiming the content was "already persisted".
  defp skipped(record, error) do
    case Ash.reload(record, authorize?: false, tenant: record.org_id) do
      {:ok, %{state: state}} when state != :draft ->
        Logger.warning(
          "collab checkpoint write-back LOST: #{inspect(record.id)} moved to #{state} " <>
            "mid-checkpoint, so `:autosave` refused it (#1015). Collaborative prose that " <>
            "no client autosave had captured is not persisted."
        )

      _still_a_draft_or_unreadable ->
        # The original meaning: an editor's save landed first and carries the
        # same converged content.
        Logger.info("collab checkpoint write-back skipped: #{Exception.message(error)}")
    end
  end
end
