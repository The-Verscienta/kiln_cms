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
  content get their `legacy_html` replaced by `Materializer.fragment_html/2`;
  everything else round-trips untouched, and a no-change checkpoint skips the
  write entirely. A stale-record failure is *fine* — it means an editor's save
  already landed with the same converged content.
  """
  require Logger

  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.Collab.Crdt.Materializer

  @doc "Materialize `doc`'s fragments into the record behind `doc_key`. Best-effort."
  @spec write_back(String.t(), Yex.Doc.t()) :: :ok
  def write_back("collab:" <> rest, doc) do
    with [kind, id] <- String.split(rest, ":", parts: 2),
         ct when not is_nil(ct) <- ContentTypes.get(kind),
         {:ok, %{state: :draft} = record} <- ContentTypes.get_record(ct, id, authorize?: false) do
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

  def write_back(_other_key, _doc), do: :ok

  defp materialize_block(%Ash.Union{type: :rich_text} = block, doc) do
    input = TypedBlocks.input_map(block)

    case input["id"] && Materializer.fragment_html(doc, "block-#{input["id"]}") do
      # No id or an empty/absent fragment (never collaboratively edited):
      # keep the stored HTML.
      nil -> input
      html -> Map.put(input, "legacy_html", html)
    end
  end

  defp materialize_block(block, _doc), do: TypedBlocks.input_map(block)

  defp save(record, blocks_input) do
    record
    |> Ash.Changeset.for_update(:autosave, %{blocks: blocks_input}, authorize?: false)
    |> Ash.update()
    |> case do
      {:ok, _saved} ->
        :ok

      {:error, error} ->
        # StaleRecord ⇒ an editor saved first (converged content already
        # persisted); anything else is logged but never crashes the DocServer.
        Logger.info("collab checkpoint write-back skipped: #{Exception.message(error)}")
        :ok
    end
  end
end
