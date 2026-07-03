defmodule KilnCMS.Collab.Crdt do
  @moduledoc """
  Real-time **CRDT text collaboration** — the prototype from
  `docs/collaborative-editing-spike.md` (scoping D1: rich text within a
  block). Complements `KilnCMS.Collab`, the coarse block-op/event layer: block
  add/remove/reorder stays op-based; concurrent typing *inside* a rich-text
  block converges through Yjs.

  The BEAM is a first-class Yjs node: one `KilnCMS.Collab.Crdt.DocServer` per
  open document holds the authoritative `Yex.Doc`, applies binary Yjs updates
  relayed over `KilnCMSWeb.CollabChannel`, and hands the full state to each
  joining client. Browsers run TipTap's Collaboration extension bound to a
  per-block `XmlFragment` of the same doc (see `assets/js/collab.js`).

  Behind the `:collab_prototype` config flag (on in dev, off in prod) — the
  channel refuses joins when disabled, so shipping the code is inert.

  Docs are **durable across restarts**: each DocServer lazy-restores its Yjs
  state from `collab_doc_states`, checkpoints while dirty, and flushes on
  shutdown (see `DocServer`). Content durability additionally flows through
  the editor's HTML-mirror autosave, so even a hard kill loses no prose.
  """

  alias KilnCMS.Collab.Crdt.DocServer

  @doc "Whether the collaborative-editing CRDT prototype is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:kiln_cms, :collab_prototype, false)

  @doc "Find or start the authoritative doc server for a channel topic."
  @spec ensure_server(String.t()) :: {:ok, pid()}
  def ensure_server(doc_key) do
    case DynamicSupervisor.start_child(KilnCMS.Collab.Crdt.DocSupervisor, {DocServer, doc_key}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  defdelegate attach(server), to: DocServer
  defdelegate apply_update(server, update), to: DocServer
  defdelegate state_update(server), to: DocServer
end
